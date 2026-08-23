# ID Token `at_hash` / `c_hash` のハッシュアルゴリズム整合（alg agility）

## 1. タイトル

ID Token の `at_hash`（および将来 Hybrid Flow で必要となる `c_hash`）を計算する際のハッシュアルゴリズムが、**ID Token の署名アルゴリズム（JOSE Header の `alg`）に追従していない**問題の確認と是正方針。現在の実装は ID Token の署名 alg に関わらず常に SHA-256 でハッシュを取るため、RS384 / RS512 / ES384 / ES512 で署名された ID Token に対しては誤った `at_hash` を発行する。

## 2. このトピックで確認したいこと

- OIDC Core 1.0 §3.1.3.6 が定める「`at_hash` のハッシュ関数は **ID Token の JOSE Header `alg` で使われるハッシュ関数**と同じものを使う」要件に対し、本リポジトリの発行ロジックが追従しているか。
- 現状の `computeAtHash()` は `crypto.subtle.digest('SHA-256', ...)` 固定であり、ID Token の署名鍵が RS384 / RS512 / ES384 / ES512 のときに **仕様違反の `at_hash`** を生成する。
- 本ライブラリは `getJwaAlgorithm()` / `selectSigningKeyByAlg()` / `extractAlgorithmParamsFromJwk()` を通じて RS256/384/512・ES256/384/512 の鍵を**実際に署名可能**であり（T-022 で複数鍵登録に対応済み）、ハッシュ固定は「鍵は多様化できるが `at_hash` だけが SHA-256 に取り残されている」という不整合を生む。
- これは "Fidelity（Conformance 準拠を信頼性のシグナルに）" を掲げる本 OSS のコンセプトに直接関わる。SHA-256 系（RS256/ES256）だけを使う限り顕在化しないが、**Basic OP の at_hash テストは「含めるなら正しいこと」を要求する**ため、非 SHA-256 鍵を登録した瞬間に相互運用性が壊れる潜在バグ。
- 既存ファイル `study-material/ext-multiple-response-types-hybrid-flow.md` は Hybrid Flow（未実装）の文脈で `at_hash` / `c_hash` を「alg ごとに正しく書く必要がある」と触れているが、**既に出荷済みの Authorization Code Flow（Basic OP の主経路）で `at_hash` が SHA-256 固定になっている欠陥**そのものは扱っていない。本ファイルでその差分に絞って整理する。

## 3. 関連する仕様・基準

共通の ID Token 仕様の索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有の核心は「ハッシュ関数の選択ルール」である。

### 3.1 OIDC Core 1.0 §3.1.3.6 — at_hash の定義（ハッシュ alg 追従）

- `at_hash`（Access Token hash value）の値は、
  「access_token の ASCII オクテット列を**ハッシュした結果の左半分（left-most half）を base64url エンコードしたもの**。**使用するハッシュアルゴリズムは ID Token の JOSE Header `alg` パラメータで使われるハッシュアルゴリズム**である。」
- 仕様の例示: 「`alg` が **RS256** なら access_token を **SHA-256** でハッシュし、**左から 128 bit** を取り base64url する。」
- 一般化すると `alg` の末尾桁がハッシュ長を決める:
  | ID Token `alg` | ハッシュ関数 | ダイジェスト長 | left-most half |
  |---|---|---|---|
  | RS256 / ES256 / PS256 / HS256 | SHA-256 | 32 bytes | 16 bytes (128 bit) |
  | RS384 / ES384 / PS384 / HS384 | SHA-384 | 48 bytes | 24 bytes (192 bit) |
  | RS512 / ES512 / PS512 / HS512 | SHA-512 | 64 bytes | 32 bytes (256 bit) |
- Authorization Code Flow（`response_type=code`、Token Endpoint 発行）では `at_hash` は **OPTIONAL**。つまり「含めなくてもよいが、**含めるなら上記ルールで正しく算出**しなければならない」。

### 3.2 OIDC Core 1.0 §3.3.2.11 — c_hash の定義（同じハッシュ alg 追従ルール）

- Hybrid Flow で `code` を Authorization Endpoint から返す場合、ID Token に `c_hash`（Code hash value）を含める。算出ルールは `at_hash` と同一（ID Token の `alg` のハッシュ関数で code をハッシュ → 左半分 → base64url）。
- 本リポジトリは Hybrid Flow 未実装のため `c_hash` は現状不要だが、**同じ算出ヘルパーを使うなら最初から alg 追従にしておく**のが自然（`ext-multiple-response-types-hybrid-flow.md` の候補 B/C を採用する際の前提条件）。

### 3.3 RP 側の検証（なぜ壊れるのか）

- OIDC Core 1.0 §3.1.3.8 / §3.3.2.12: RP は受け取った ID Token の `alg` を見て、対応するハッシュ関数で access_token / code をハッシュし直し、`at_hash` / `c_hash` と**一致するか MUST 検証**できる（at_hash は OPTIONAL だが、存在すれば検証する RP がある）。
- OP が ES384 で署名した ID Token に **SHA-256 由来の `at_hash`** を入れると、RP は SHA-384 で再計算するため**必ず不一致**になり、厳格な RP は ID Token を拒否する。SHA-256 系鍵だけ使う限りは偶然一致して問題が表面化しない。

## 4. 参照資料

- OpenID Connect Core 1.0 §3.1.3.6 (ID Token) — https://openid.net/specs/openid-connect-core-1_0.html#CodeIDToken
  - 根拠箇所:「at_hash ... where the hash algorithm used is the hash algorithm used in the `alg` Header Parameter of the ID Token's JOSE Header. For instance, if the `alg` is RS256, hash the access_token value with SHA-256, then take the left-most 128 bits and base64url-encode them.」
- OpenID Connect Core 1.0 §3.3.2.11 (c_hash) — https://openid.net/specs/openid-connect-core-1_0.html#HybridIDToken
- OpenID Connect Core 1.0 §3.1.3.8 / §3.3.2.12 (ID Token Validation, at_hash/c_hash 検証) — https://openid.net/specs/openid-connect-core-1_0.html#IDTokenValidation
- JSON Web Algorithms (JWA) RFC 7518 §3.1 — https://datatracker.ietf.org/doc/html/rfc7518#section-3.1 （RSxxx / ESxxx と SHA-xxx の対応表）
- 本リポジトリ該当箇所:
  - `packages/core/src/token-response.ts` の `computeAtHash()`（SHA-256 固定）と `generateTokenResponse()`（`idtKey` で ID Token を署名）
  - `packages/core/src/crypto-utils.ts` の `getJwaAlgorithm()`（CryptoKey → RS256/384/512・ES256/384/512）
  - `packages/core/src/signing-key.ts` の `selectSigningKeyByAlg()`（クライアントの `id_token_signed_response_alg` に応じて鍵選択。T-022）
- 関連既存ファイル: `study-material/ext-multiple-response-types-hybrid-flow.md`（Hybrid Flow 文脈の at_hash/c_hash。本ファイルは Code Flow の既存欠陥に限定）

## 5. 現在の実装確認

`packages/core/src/token-response.ts`:

```ts
// at_hash を計算する (OIDC Core 1.0 Section 3.1.3.6)
async function computeAtHash(accessToken: string): Promise<string> {
  const tokenBytes = stringToArrayBuffer(accessToken);
  const hashBuffer = await crypto.subtle.digest('SHA-256', tokenBytes); // ← SHA-256 固定
  const leftHalf = hashBuffer.slice(0, hashBuffer.byteLength / 2);
  return arrayBufferToBase64Url(leftHalf);
}
```

- `leftHalf = slice(0, byteLength / 2)` の「左半分」ロジック自体は alg 非依存で正しい（SHA-384→24 bytes、SHA-512→32 bytes に自然に一般化される）。**欠陥は `digest('SHA-256', ...)` のハッシュ関数固定の一点**。
- `generateTokenResponse()` 内で ID Token は `idtKey = idTokenPrivateKey ?? privateKey` で署名され、署名 alg は `generateIdToken()` 内で `getJwaAlgorithm(idtKey)` により決まる。一方 `computeAtHash(accessToken)` は `idtKey` を一切参照しない。→ **「ID Token の署名 alg」と「at_hash のハッシュ alg」が構造的に分離している**。
- サンプル設定（`packages/sample/src/oidc-provider/config.ts`）の `idTokenSignedResponseAlg` は現状 `'RS256' | 'ES256'` のみ（いずれも SHA-256）。このためサンプル経路では顕在化しない**潜在バグ**。ただし core は ES512 等の鍵登録を妨げない。
- テスト: `token-response.test.ts` に at_hash のテストは存在するが、RS256/ES256（SHA-256）前提のため SHA-384/512 のミスマッチを検出できていない。

## 6. 現在の実装との差分

満たしていること:
- ✅ RS256 / ES256（SHA-256）で署名する ID Token の `at_hash` は仕様通り正しい（Basic OP のデフォルト RS256 経路は問題なし）。
- ✅ 「左半分を取って base64url」のエンコードは alg 非依存に正しい。
- ✅ Code Flow で at_hash は OPTIONAL であり、含める設計判断自体は許容される。

不足している可能性があること:
- ❌ RS384 / RS512 / ES384 / ES512 で署名された ID Token の `at_hash` が **SHA-256 由来となり仕様違反**。これらの鍵は core が署名可能（`getJwaAlgorithm` 対応）かつ T-022 で複数鍵登録に対応済みのため、現実に発生し得る。
- ❌ `at_hash` のハッシュ alg を「ID Token の実署名鍵」から導出する経路が無い。

セキュリティ／相互運用性の観点:
- ⚠️ 相互運用性: 非 SHA-256 鍵を使った瞬間に、厳格な RP が ID Token を `at_hash` 不一致で拒否し、ログインが失敗する（サイレントに壊れる）。
- ⚠️ Conformance: OP が `id_token_signing_alg_values_supported` に ES384/512 等を広告しつつ at_hash が誤る状態は、Basic OP / 各 Conformance プロファイルの at_hash チェックで落ちる。

Basic OP として提供する上で確認すべきこと:
- Code Flow の at_hash は OPTIONAL のため「**そもそも at_hash を発行するか**」も設計判断になる。発行を続けるなら alg 追従の修正が必須。発行を SHA-256 系に限定するなら「非 SHA-256 鍵を登録したらエラー or at_hash 省略」のガードが必要。

## 7. 改善・追加を検討する理由

- **なぜ価値があるか**: "Fidelity" を看板にする OSS で、署名 alg を多様化できる（=売りの一つ）のに at_hash がそれに追従しないのは、自己矛盾かつ「最も気づきにくい相互運用バグ」。修正は小さく、コンセプトへの寄与は大きい。
- **Basic OP に必要か / 拡張か**: at_hash 自体は Code Flow で OPTIONAL だが、本実装は**常に発行している**。「発行するなら正しく」が原則なので、Basic OP 準拠の**バグ修正**に分類される（新機能ではない）。
- **導入しやすさ**: ハッシュ関数を 1 箇所で切り替えるだけ。`getJwaAlgorithm(idtKey)` から SHA-256/384/512 を導く小さなマップを足せばよい。既存の `leftHalf` ロジックはそのまま使える。
- **既存実装との接続**: `generateTokenResponse()` は既に `idtKey` を保持しているため、`computeAtHash(accessToken, getJwaAlgorithm(idtKey))` と渡すだけで接続できる。`crypto-utils.ts` に「alg → SubtleCrypto ハッシュ名」変換を集約すると Hybrid Flow の `c_hash` でも再利用できる。
- **利用者メリット**: PoC 利用者が「ES384 で試したら RP 側で ID Token 検証が落ちる」という再現困難なハマりを回避できる。
- **実装しない場合のリスク**: 非 SHA-256 鍵を選んだ利用者が静かに壊れる。Conformance 取得時に at_hash テストで失敗する。`ext-multiple-response-types-hybrid-flow.md` の Hybrid 実装に進む際、同じバグを c_hash に持ち込む。

## 8. 実装方針の候補

> 最終判断は人間が行う。以下は判断材料。

### 候補 A: ハッシュ alg を ID Token 署名鍵から導出して修正（推奨度: 高）
- `crypto-utils.ts` に `jwaToHashName(alg: string): 'SHA-256' | 'SHA-384' | 'SHA-512'` を追加（RS256/ES256→SHA-256, ...384→SHA-384, ...512→SHA-512）。
- `computeAtHash(value, hashName)` 化し、`generateTokenResponse()` で `getJwaAlgorithm(idtKey)` から hashName を求めて渡す。
- `leftHalf = slice(0, byteLength/2)` は維持（自動で 16/24/32 bytes に一般化）。
- Hybrid Flow の `c_hash` でも同じ `computeHash(value, hashName)` を共用できるよう汎用名にしておく。

### 候補 B: at_hash を SHA-256 系鍵に限定（発行を絞る）
- ID Token 署名鍵が非 SHA-256 のときは at_hash を**省略**（Code Flow では OPTIONAL なので許容）。
- 実装は軽いが、「鍵は多様化できるのに at_hash だけ出ない」という非対称が残る。Hybrid Flow へ進むと c_hash は省略不可なので結局候補 A が必要になる。

### 候補 C: 現状維持＋ガード
- 非 SHA-256 の ID Token 署名鍵登録時に「at_hash 未対応」を明示エラーにする。誤った at_hash を出すよりは安全だが、機能制約として残る。暫定対応向け。

### 補足: c_hash の扱い
- 本修正で導入する `jwaToHashName` / `computeHash` を共通化しておけば、`ext-multiple-response-types-hybrid-flow.md` 候補 B/C 採用時に `c_hash` をそのまま正しく実装できる。本ファイルのスコープは at_hash の是正に限定し、c_hash の実装可否は Hybrid Flow 側で判断する。

## 9. タスク案

- [ ] `crypto-utils.ts` に `jwaToHashName(alg)` を追加し、RS/ES/(PS) の 256/384/512 を SHA-256/384/512 に写像する（未知 alg は例外）。
- [ ] `computeAtHash` をハッシュ名引数つきに変更（または汎用 `computeLeftHalfHash(value, hashName)` を新設）。
- [ ] `generateTokenResponse()` で ID Token の実署名鍵 `idtKey` から `getJwaAlgorithm` → `jwaToHashName` を求めて at_hash 計算に渡す。
- [ ] `token-response.test.ts` に RS256/ES256（SHA-256）に加えて **RS384/RS512/ES384/ES512** で署名した ID Token の at_hash 長と値を検証するテストを追加（OIDC Core §16.11 のテストベクトル、または自前で SHA-384/512 → 左半分 → base64url を計算して期待値化）。
- [ ] at_hash の left-most half バイト長が 16 / 24 / 32 になることのアサーション。
- [ ] （任意）Hybrid Flow を見据え `computeLeftHalfHash` を `index.ts` から export するか検討（c_hash 共用）。
- [ ] 完了確認コマンド: `pnpm --filter @maronn-openid-connect/core test`
