# JWS アルゴリズムポリシーと `alg=none` 防御（鍵集合・受け入れ alg・JOSE 検証戦略）

## ステータス

🟡 Major（セキュリティ）/ 未着手

## 1. このトピックで確認したいこと

本リポジトリは ID Token / UserInfo JWT / `id_token_hint` 検証など、複数の経路で **JWS（JSON Web Signature）の生成・検証**を行う。
ここでは「どの `alg` を許容し、どの `alg` を拒否するか」「`alg=none` の取り扱い」「鍵と alg の結びつけ（key alg pinning）」「アルゴリズム混同攻撃（algorithm confusion）」「`crit` ヘッダーの扱い」を、Basic OP / OAuth 2.0 JOSE BCP（RFC 8725）の観点でレビューする。

具体的な単発タスク（`T-016-rs256-enforcement.md` の RS256 必須、`tasks/done/oidc-improvements-2026-05.md` 等）は個別に追跡済みだが、「**JWS アルゴリズムポリシー全体を横断する設計文書**」が無い。Basic OP の中核は ID Token の JOSE 検証可能性なので、ここを別建てで整理しておく価値が高い。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイント:

- **OIDC Core 1.0 §15.1**: OP は RS256 を必須で実装。`id_token_signed_response_alg` で他 alg を選択させる場合も RS256 鍵は必ず保持する。
- **OIDC Core 1.0 §2 / §16.18**: ID Token の検証は JWS（RFC 7515）に従う。`alg` パラメータを単独で信用しない。受信側は **事前に許容 alg を決め**、ヘッダーの `alg` がその集合に属するかをチェックしてから検証する。
- **OIDC Core 1.0 §10.1 / §16**: `none` を含む `alg` のフィルタは受信側責任。OP は ID Token を **`alg=none` で発行しない**。
- **JWA（RFC 7518）§3.1**: `none` はクライアントが OP との間で明示的に交渉した場合に限り使用可能とされるが、Basic OP の OP には不適切。
- **RFC 8725（JSON Web Token Best Current Practices）**:
  - §3.1: 受信側は **`alg` ヘッダー値を許容リストと突き合わせる**。鍵集合から alg を引いてはならない（algorithm confusion 防止）。
  - §3.2: 鍵には alg をピンする（1 鍵 = 1 alg）。
  - §3.3: `none` を恒久的に許容しない。
  - §3.5: RSA 公開鍵を HMAC 鍵として誤用させる「HS256 confusion」を防ぐ。
  - §3.6: `kid` の入力検証。
  - §3.7: `crit` ヘッダーは知らない値があれば拒否（RFC 7515 §4.1.11）。
- **OAuth 2.1 §7**: PKCE と並び、JOSE 関連の BCP を引用しているため、OP は本 BCP に追従する。

## 3. 参照資料

- OpenID Connect Core 1.0 §2, §15.1, §16: https://openid.net/specs/openid-connect-core-1_0.html
- RFC 7515 JWS: https://www.rfc-editor.org/rfc/rfc7515
- RFC 7518 JWA §3.1（"none" の扱い）: https://www.rfc-editor.org/rfc/rfc7518#section-3.1
- RFC 8725 JWT BCP: https://www.rfc-editor.org/rfc/rfc8725
- RFC 9068 JWT Access Token（`typ=at+jwt`）: https://www.rfc-editor.org/rfc/rfc9068

## 4. 現在の実装確認

- ID Token / Refresh AT 等の **発行側**:
  - `packages/core/src/signing-key.ts`:
    - `assertHasRs256Key()` で RS256 鍵が登録されているかを起動時にチェック（OIDC Core §15.1 強制）
    - `selectSigningKeyByAlg()` で「クライアントの `id_token_signed_response_alg` または既定 `RS256`」を選ぶ
    - 鍵集合は array 順で「古い→新しい」、最後一致が勝つ（rotation 中の優先）
  - `packages/core/src/discovery.ts:160-178`: 広告する `id_token_signing_alg_values_supported` は **登録鍵から派生**（手動列挙を許さない）。`assertHasRs256Key()` を通過しないと build 失敗。
- **検証側**（`id_token_hint`）:
  - `packages/core/src/id-token.ts:227-249`:
    - ヘッダー `alg` が無い / `none` を即拒否（`IdTokenHintError('id_token_hint alg is missing or "none"')`）
    - `kid` 一致を優先し、無ければ `alg` 一致で候補絞り込み
    - 候補 JWK の `jwk.alg !== headerAlg` の場合は検証せず次へ進む（**alg confusion 抑止**）
    - 公開鍵 import 時に JWK の alg メタを使う（`extractAlgorithmParamsFromJwk`）
- 既存タスクで完了済み:
  - `tasks/done/T-016-rs256-enforcement.md`（RS256 必須の起動チェック）
  - `tasks/done/p0-userinfo-signed-response-wiring.md`（UserInfo 署名応答の wiring）

## 5. 現在の実装との差分

満たしていること:

- 発行側で `assertHasRs256Key()` により RS256 必須を強制（Basic OP §15.1 充足）
- 広告 alg をキー集合から派生（広告と実態の乖離防止）
- `id_token_hint` 検証で `alg=none` 明示拒否、`jwk.alg vs headerAlg` 一致前提（algorithm confusion 抑止）
- `kid` ベースの鍵選択、複数鍵環境での import 失敗時 skip など、JOSE 基本動作は備える

不足／曖昧な点:

- 🟡 **alg 許容リストの集約点が無い**: 「OP として何 alg を受け入れて何を拒否するか」の **一覧表**が core にも CLI にも無い。`alg=none` は `id_token_hint` 検証ではガードされているが、もし将来 client_assertion（`private_key_jwt`）等を追加した際に、**同じ allowlist パターンが各検証点で再実装**される懸念がある（一元化されていない）。
- 🟡 **HMAC 系 alg（HS256 等）の扱いが不明**: 現状 HMAC 鍵は登録経路が無く、`id_token_signed_response_alg=HS256` を要求された場合の挙動が core ドキュメントに無い。RFC 8725 §3.5 に従えば、RS/PS/ES と HS を同じ alg ピンで管理しないようにする必要がある（RSA 公開鍵が HMAC 共通鍵として誤用されないようにする）。OP として HS256 をサポートしない方針なら **Discovery で広告しない／要求を拒否**を明示することが BCP 整合。
- 🟡 **`crit` ヘッダーの方針**: 現状 `id_token_hint` 検証では `crit` を読んでいない。RFC 7515 §4.1.11 / RFC 8725 §3.7 では「未知の `crit` ヘッダーパラメータ名があれば JWS を拒否」が必要。仕様準拠の検証としては要対応。
- 🟡 **JWK `alg` の必須性**: JWKS の `alg` が undefined の鍵が混在すると `id-token.ts` の `jwk.alg !== headerAlg` 比較で誤通過の余地が出る（実装的には `undefined !== 'RS256'` は true なので skip されるが、**「alg を持たない JWK は受け入れない」ことを明示的にテスト**で固定したい）。
- 🟢 **`typ` ヘッダー検証の有無**: ID Token は `typ=JWT`（または omitted）、JWT AT は `typ=at+jwt`（RFC 9068）、DPoP は `typ=dpop+jwt`、Logout は `typ=logout+jwt`。OP が **検証者になる経路**（`id_token_hint`、client_assertion、DPoP proof）で `typ` を厳格にチェックする方針かどうかが未明示。

セキュリティ的観点:

- 🔴 **アルゴリズム混同攻撃の防御**: 「OP は受信した JWS の `alg` を一切信用せず、`kid` から鍵を引き、鍵にピンされた alg で検証する」というポリシーが望ましい。現実装は `kid` 優先で動くため概ね正しいが、`kid` が無い JWS では `headerAlg` で候補を絞っている。これは正当だが、**「鍵側に `alg` がピンされていることが前提」**。テストでこの前提を固定しないと、JWKS に複数 alg の鍵が混在したとき脆弱化しうる。
- 🔴 **将来 `private_key_jwt` を追加した際**: client_assertion の `alg` 許容リストは ID Token 検証と独立なので、**OP 全体の allowlist 設計**を一度引いておく価値が大きい。

## 6. 改善・追加を検討する理由

- Basic OP の信頼の根拠は「クライアントが OP の ID Token を**安全に**検証できる」こと。発行側だけでなく、OP が JWT を受け取る経路（`id_token_hint`、将来の client_assertion）でも JOSE BCP を満たすことで、OSS としての品質シグナルになる。
- OSS 利用者が rotation / 鍵管理 / alg 追加（ES256, EdDSA など）を自前で行う際、**「どこに何を書けば安全になるか」**の地図が必要。中心となる allowlist と検証戦略を一箇所に集約しておけば、利用者が誤って `alg=none` や `HS256` 経路を有効化するリスクを抑制できる。
- 本リポジトリの差別化軸「Fidelity（Conformance 準拠を信頼性のシグナル）」に直結。Conformance Suite の ID Token 検証系テストは alg 関連の細かなエッジを叩くので、ここの明示は認定通過の確度を上げる。

実装しない場合の制約:

- 個別タスクで散発的に「`alg=none` を拒否」「RS256 必須」を直しても、**横断ポリシーが文書化されない**ので、新規拡張（DPoP、`private_key_jwt`、JAR、Federation）追加時に同じ議論を再発させる。

## 7. 実装方針の候補

### 方針A（最小・ポリシー文書化）

- `study-material/jws-algorithm-policy-and-alg-none-defense.md`（本ファイル）に「OP が受け入れる alg 一覧 / 拒否する alg 一覧 / その理由 / RFC 引用」をテーブル化。各検証経路の実装はこの文書を参照するルールにする。
- `id-token.ts` / `signing-key.ts` / 将来の `client-auth.ts` の関連箇所にコメントで本文書への参照を付ける。

### 方針B（共通ユーティリティ化）

- `packages/core/src/jose-policy.ts`（新規）に以下を集約:
  - `OP_ID_TOKEN_VERIFY_ALG_ALLOWLIST`（例: `['RS256','PS256','ES256','EdDSA']`、`none` / `HS*` を除外）
  - `assertJwsHeaderAcceptable(header, allowlist)`: `alg in allowlist`、`crit` の未知パラメータ拒否、`typ` 期待値の検証
  - `pickVerificationKey(jwks, header, allowlistByKid)`: kid 優先、`jwk.alg === header.alg` 必須
- `id_token_hint` 検証および将来の client_assertion / DPoP / logout_token 検証はすべてこのユーティリティを通す。
- HMAC 系の alg は **デフォルト無効**、明示 opt-in が必要な設計にする。

### 方針C（テストでロック）

- `tests` に以下を追加（実装変更なしでも入る）:
  - `id_token_hint` で `alg=none` の固定拒否
  - JWKS の `alg` 欠落 JWK を含む場合に検証が必ず失敗するテスト
  - `crit` ヘッダーに未知パラメータが入った JWS は拒否されるテスト（実装が `crit` を読んでいない場合は新規テストが失敗するので、結果として実装ドライブできる）

判断材料:

- 方針A は即時実施可。利用者が次の拡張を入れるときの判断材料となる。
- 方針B は code-level の中央集権化で、長期的に安全だが手戻りが出る箇所もある。
- 方針C は方針 B を強制するテストドライバとして有効。

## 8. タスク案

- [ ] 本ファイルに「受け入れ／拒否 alg 一覧」を表で固定する（必要に応じて Codex セカンドオピニオン）
- [ ] `packages/core/src/jose-policy.ts`（仮）として共通ヘルパーを切り出す可否を検討
- [ ] `id-token.ts` の `validateIdTokenHint` に `crit` ヘッダー検証を追加（未知 `crit` パラメータ拒否）
- [ ] JWKS に `alg` が無い JWK を含めた場合の検証挙動をテストで固定
- [ ] HS256 等の HMAC alg を Discovery / 検証経路で明示的に拒否するテストを追加（または「opt-in のみ」を明示）
- [ ] 既存 `T-019-dpop.md` / `ext-private-key-jwt-client-auth.md` / `ext-jar-request-object-rfc9101.md` 着手時、本ポリシーに従う旨を各タスクに追記
