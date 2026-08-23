# 受信 JWS 検証における JWK `alg` 必須化（RFC 7517 §4.4 は OPTIONAL）と候補鍵選択ロジックの非対称

## ステータス

🟡 Medium（相互運用性 / Fidelity）/ 未着手

## 1. このトピックで確認したいこと

本 OP が **外部から受け取った JWS を検証する経路**は 2 つある。

1. `validateIdTokenHint()` — `id_token_hint` の署名検証（`packages/core/src/id-token.ts`）
2. `parseRequestObject()` — `request` パラメータ（Request Object）の署名検証（`packages/core/src/request-object.ts`）

いずれも「JWK Set から候補鍵を選び、`importKey` して `verify` する」構造だが、次の 2 点を確認したい。

- **A. `alg` を持たない JWK を検証に使えない**。RFC 7517 §4.4 は JWK の `alg` を **OPTIONAL** と定めるが、
  本実装は型・実行時ロジックの両方で `alg` を事実上必須にしており、`alg` を省いた（＝仕様上まったく正当な）
  JWK Set では署名検証が**必ず失敗**する。
- **B. 2 経路で候補鍵の選び方が非対称**。同じ「受信 JWS の検証」でありながら、`kid` 無しのときの候補集合の
  作り方・`alg` 不一致時の扱いが `id-token.ts` と `request-object.ts` で異なる。片方を直しても他方に反映されない
  構造であり、将来の鍵ポリシー変更（PS256 追加、EdDSA 追加など）で挙動が割れる。

> **既存ファイルとの切り分け（重複回避）**
>
> | 論点 | 扱っているファイル |
> |---|---|
> | `crit` ヘッダ未拒否 / `alg` とヘッダの束縛（セキュリティ・ハードニング） | `study-material/inbound-jws-verification-crit-and-alg-binding.md` |
> | 受け入れ `alg` の集合ポリシー / `alg=none` 防御 | `study-material/jws-algorithm-policy-and-alg-none-defense.md` |
> | 自分が**公開する** JWKS の `kid` / `use` / 鍵強度 | `study-material/jwks-endpoint-comprehensive.md`、`study-material/done/signing-key-strength-and-parameter-validation.md`、`study-material/done/id-token-kid-presence-under-multiple-keys.md` |
> | `kid` を必ず載せる（発行側） | `tasks/done/p2-id-token-kid-required-under-multiple-keys.md` |
>
> 上記はいずれも「**危険な入力を拒否する**」または「**自分が出す鍵**」の話である。
> 本ファイルは逆方向、すなわち「**仕様上正当な入力（`alg` なし JWK）を拒否してしまっている**」という
> 相互運用性の欠落と、2 経路の実装非対称に限定する。仕様の共通説明は上記ファイルを参照し繰り返さない。

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 RFC 7517 §4.4 — `alg` は OPTIONAL

> **4.4. "alg" (Algorithm) Parameter**
> The "alg" (algorithm) parameter identifies the algorithm intended for use with the key.
> The values used should either be registered in the IANA "JSON Web Signature and Encryption
> Algorithms" registry ... **Use of this member is OPTIONAL.**

同じく §4.2 `use`（Public Key Use）も **OPTIONAL**、§4.5 `kid` も **OPTIONAL** である。
つまり `{"kty":"RSA","n":"...","e":"AQAB"}` だけの JWK Set は完全に仕様適合であり、
検証側はこれを扱えることが望ましい。

### 2.2 RFC 7515 §4.1.1 — `alg` の権威は JOSE ヘッダ側にある

> **4.1.1. "alg" (Algorithm) Header Parameter**
> The "alg" (algorithm) Header Parameter identifies the cryptographic algorithm used to
> secure the JWS. ... This Header Parameter MUST be present and MUST be understood and
> processed by implementations.

署名アルゴリズムを決めるのは **JWS ヘッダの `alg`** であって JWK の `alg` ではない。
JWK の `alg` は「この鍵はこの alg でのみ使ってよい」という**任意の制約宣言**であり、
存在すれば JWS ヘッダの `alg` と一致することを要求する（＝ダウングレード防止）のは正しい。
しかし**存在しない場合に検証不能にする**根拠は RFC 7515 / RFC 7517 のいずれにも無い。

RFC 8725（JWT BCP）§3.1 も「`alg` はヘッダを鵜呑みにせず**鍵に紐づく期待アルゴリズム**と突き合わせよ」と
述べるが、その「期待アルゴリズム」は JWK の `alg` フィールドだけでなく、`kty` / `crv` などの鍵素材から
導出したものでもよい。実際、`kty=EC` + `crv=P-256` の鍵は ES256 以外では使えないため、
`alg` が無くても曖昧さはない。

### 2.3 現実の JWKS における `alg` の有無

`alg` は OPTIONAL であるため、実際の JWKS には両方が存在する。
本リポジトリが検証対象とするのは **クライアントが登録した JWKS**（Request Object 用）と
**利用者が `jwksProvider` として注入した鍵集合**（`id_token_hint` 用）であり、どちらも
本 OP の統制下に無い外部データである。したがって「`alg` があるとは限らない」前提で
設計する必要がある。

## 3. 参照資料

- RFC 7517 JSON Web Key §4.2 `use` / §4.4 `alg` / §4.5 `kid`（いずれも Use of this member is OPTIONAL）
  — https://www.rfc-editor.org/rfc/rfc7517#section-4.4
- RFC 7515 JSON Web Signature §4.1.1 `alg` Header Parameter（MUST be present in the JOSE header）
  — https://www.rfc-editor.org/rfc/rfc7515#section-4.1.1
- RFC 7518 JSON Web Algorithms §3.1（`alg` 値と鍵種別の対応）/ §6.2.1.1 `crv`
  — https://www.rfc-editor.org/rfc/rfc7518#section-3.1
- RFC 8725 JSON Web Token Best Current Practices §3.1 / §3.2（アルゴリズム確認・鍵と alg の束縛）
  — https://www.rfc-editor.org/rfc/rfc8725#section-3.1
- OpenID Connect Core 1.0 §6.1（Request Object の署名）/ §3.1.2.1（`id_token_hint`）
  — https://openid.net/specs/openid-connect-core-1_0.html#RequestObject
- 本リポジトリ内: `packages/core/src/crypto-utils.ts`（`extractAlgorithmParamsFromJwk`）、
  `packages/core/src/id-token.ts`（`validateIdTokenHint`）、
  `packages/core/src/request-object.ts`（`parseRequestObject`）、
  `packages/core/src/jwks.ts`（`Jwk` 型）

## 4. 現在の実装確認

### 4.1 `Jwk` 型が `alg` / `use` を必須にしている

`packages/core/src/jwks.ts`:

```ts
export interface Jwk {
  kty: string;
  use: string;   // ← RFC 7517 §4.2 では OPTIONAL
  alg: string;   // ← RFC 7517 §4.4 では OPTIONAL
  kid?: string;
  n?: string; e?: string;
  crv?: string; x?: string; y?: string;
  ...
}
```

この型は「本 OP が**公開する** JWKS」を表現する用途（`exportPublicJwk` の戻り値）としては妥当だが、
**受信検証用の JWK Set の型としても同じものが使われている**（`parseRequestObject` の
`options.jwks: JwkSet`、`validateIdTokenHint` の `jwks`）。結果として、TypeScript 利用者は
クライアント登録 JWKS を渡す際に、実データに無い `alg` / `use` を手で補うことを強制される。

### 4.2 `extractAlgorithmParamsFromJwk` は RSA JWK に `alg` を要求する

`packages/core/src/crypto-utils.ts`:

```ts
export function extractAlgorithmParamsFromJwk(jwk) {
  if (jwk.kty === 'RSA') {
    const alg = jwk.alg;
    const hash = alg === 'RS256' ? 'SHA-256' : alg === 'RS384' ? 'SHA-384'
               : alg === 'RS512' ? 'SHA-512' : null;
    if (!hash) {
      throw new Error(`Unsupported RSA alg: ${alg ?? '(missing)'}`);   // ← alg 欠落で throw
    }
    return { name: 'RSASSA-PKCS1-v1_5', hash };
  }
  if (jwk.kty === 'EC') {
    const crv = jwk.crv;                                               // ← EC は crv から導出（alg 不要）
    if (crv !== 'P-256' && crv !== 'P-384' && crv !== 'P-521') { throw ... }
    return { name: 'ECDSA', namedCurve: crv };
  }
  throw new Error(`Unsupported kty: ${jwk.kty ?? '(missing)'}`);
}
```

- **EC**: `crv` から `namedCurve` を導出しており `alg` は不要（＝仕様どおり動く）。
- **RSA**: `alg` が無いと `hash` を決められず throw する。ただし JWS ヘッダの `alg`（`RS256` 等）が
  分かっていれば `hash` は一意に決まるため、**情報は揃っているのに使っていない**。

### 4.3 `validateIdTokenHint` は `alg` の無い JWK を候補から完全に排除する

`packages/core/src/id-token.ts`:

```ts
const candidates = headerKid
  ? jwks.keys.filter((k) => k.kid === headerKid)
  : jwks.keys.filter((k) => k.alg === headerAlg);   // ← alg 未設定の鍵はここで全滅

if (candidates.length === 0) {
  throw new IdTokenHintError('No JWK matched the id_token_hint header');
}

for (const jwk of candidates) {
  if (jwk.alg !== headerAlg) {
    continue;                                        // ← kid 一致でも alg 未設定なら skip
  }
  ...
}
```

`kid` で一意に選べた場合でも `jwk.alg !== headerAlg` で弾かれるため、
**`alg` を持たない JWK では `id_token_hint` の検証が必ず失敗する**（`login_required` 等に落ちる）。

### 4.4 `parseRequestObject` は「`alg` があるときだけ突き合わせる」が、結局 4.2 で落ちる

`packages/core/src/request-object.ts`:

```ts
const candidates: Jwk[] = kid
  ? jwks.keys.filter((k) => k.kid === kid)
  : jwks.keys.slice();                      // ← kid 無しなら全鍵を候補にする（id-token.ts と異なる）

for (const jwk of candidates) {
  if (jwk.alg && jwk.alg !== alg) {
    continue;                               // ← alg があるときだけ突き合わせる（正しい挙動）
  }
  try {
    const algParams = extractAlgorithmParamsFromJwk(jwk);   // ← RSA かつ alg 無しならここで throw
    publicKey = await crypto.subtle.importKey(...);
  } catch {
    continue;                                               // ← 握り潰して次の鍵へ
  }
  ...
}
throw new RequestObjectError('request object signature verification failed');
```

候補選択の段階では `alg` 欠落を正しく許容しているが、鍵の import で `extractAlgorithmParamsFromJwk` が
throw し、`catch { continue }` で握り潰されるため、**RSA + `alg` 無しでは結局検証できない**。
しかも失敗理由は「署名検証失敗」に丸められ、「鍵をロードできなかった」という原因が利用者に届かない。

### 4.5 2 経路の非対称のまとめ

| 観点 | `validateIdTokenHint`（id-token.ts） | `parseRequestObject`（request-object.ts） |
|---|---|---|
| `kid` 無しのときの候補 | `alg` 一致する鍵のみ | **全鍵** |
| RSA + `alg` 無し | 検証不能（候補から除外される） | 検証不能（候補には残るが `extractAlgorithmParamsFromJwk` が throw） |
| EC + `alg` 無し | **検証不能**（`k.alg === headerAlg` / `jwk.alg !== headerAlg` で除外される） | **検証できる**（`crv` から導出されるため import も verify も成功する） |
| 失敗時のエラー | `No JWK matched...` / `signature verification failed` | 一律 `signature verification failed` |
| `crit` 拒否・外部鍵ヘッダ拒否 | `assertNoExternalKeyHeaders` あり | （`inbound-jws-verification-crit-and-alg-binding.md` 参照） |

同じ「受信 JWS の検証」に対して 4 行程度の分岐が別々に書かれており、片方を直しても他方に伝播しない。

## 5. 現在の実装との差分

### 満たしていること

- ✅ JWS ヘッダの `alg` が `none` の場合の拒否（両経路）。
- ✅ JWK に `alg` が**ある**場合に JWS ヘッダの `alg` と一致を要求する（RFC 8725 §3.1 のアルゴリズム束縛）。
- ✅ `kid` があるときの一意な鍵選択。
- ✅ EC 鍵の `crv` からのアルゴリズム導出（`alg` 非依存）。ただしこれが実際に活きるのは
  `parseRequestObject` 経路のみで、`validateIdTokenHint` は候補選択の段階で `alg` 一致を要求するため
  EC 鍵でも `alg` が無ければ使えない（＝4.5 の非対称の実例）。

### 不足している可能性があること

- 🟡 **RFC 7517 §4.4 で OPTIONAL の `alg` を実質必須にしている**。仕様適合な JWK Set を拒否するため、
  Fidelity（仕様忠実性）と相互運用性の両方を損なう。JWS ヘッダの `alg` と `kty` / `crv` から
  import パラメータは一意に決まるので、技術的な障害は無い。
- 🟡 **`Jwk` 型が `alg: string` / `use: string` を必須にしている**。発行用と受信検証用で同じ型を使い回して
  いるため、TypeScript 利用者は実在しないフィールドを捏造して渡すことになる（＝型が実データを表していない）。
- 🟡 **候補鍵選択ロジックの二重実装**。将来 `PS256`（`tasks/p2-signing-alg-ps256.md`）や EdDSA を
  追加すると、片方だけ更新されて挙動が割れるリスクがある。
- 🟢 **失敗理由が利用者に届かない**。`catch { continue }` で「鍵をロードできない」と「署名が合わない」が
  同じエラーに丸められる。PoC 検証ツールとしては原因切り分けができないのは体験上の損失。

### 実装はあるが仕様上の確認が必要なこと

- `alg` 欠落を許容する場合でも、**アルゴリズム・ダウングレードを許してはならない**。
  許容すべきは「`alg` が無い鍵に対して、JWS ヘッダの `alg` を鍵素材（`kty` / `crv`）と整合する範囲で適用する」
  ことだけであり、`kty=EC` + `crv=P-256` の鍵に `RS256` を適用するような組み合わせは
  引き続き拒否されなければならない（WebCrypto の `importKey` が型不一致で失敗するため自然に守られるが、
  明示的にテストで固定すべき）。
- `use` が `enc` の鍵を署名検証に使わない、というチェックは現状どちらの経路にも無い
  （`study-material/done/signing-key-strength-and-parameter-validation.md` の「自分の鍵」側の論点と対になる、
  受信側の論点。本トピックで併せて扱うかは判断が必要）。

### セキュリティ上、改善した方がよいこと

- `alg` 欠落を許容するなら、**受け入れ可能な `alg` の集合**（`DEFAULT_REQUEST_OBJECT_SIGNING_ALGS` /
  `id_token_hint` の期待 alg）による事前フィルタは維持することが前提。ここは
  `study-material/jws-algorithm-policy-and-alg-none-defense.md` の方針に従う。

### 相互運用性の観点

- 🟡 クライアントが `jose` などの一般的なライブラリで鍵を書き出すと `alg` が付かないことがある。
  その JWKS をそのまま登録した利用者は、Request Object が常に `signature verification failed` になり、
  原因（`alg` フィールドの欠落）に到達できない。

### Basic OP として提供する上で確認すべきこと

- Basic OP certification のブロッカーではない（`request` / `id_token_hint` の署名検証は Basic OP の
  必須要件ではなく、OIDF Conformance Suite が使う鍵は `alg` を含む）。
  本トピックは **Fidelity と OSS 利用者体験**の軸で扱う。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: 「仕様どおりに書いたのに動かない」は OSS で最も離脱を招く体験である。
  本ライブラリのコンセプトは「仕様を素早く忠実に検証できる」ことなので、
  **仕様適合な入力を拒否する**のはコンセプトそのものへの反例になる。
- **Basic OP に必要か、拡張として有用か**: Basic OP の必須要件ではない。ただし
  `request` パラメータ対応（`tasks/done/p1-basic-op-request-object-by-value.md`）を実装済みで
  Discovery で `request_parameter_supported: true` を広告している以上、
  「広告した機能が現実の JWKS で動かない」状態は honesty の問題になる
  （`study-material/request-object-rejection-and-discovery-honesty.md` の思想と同じ軸）。
- **導入しやすさ**: 🟢 高い。変更点は
  (1) `extractAlgorithmParamsFromJwk` に「JWS ヘッダ `alg` を補助情報として受け取る」オーバーロードを足す、
  (2) 候補鍵選択を 1 つの共有ヘルパへ寄せる、の 2 点で、いずれも `packages/core` に閉じる。
  外部依存は増えない（Web 標準 API のみ）。
- **既存実装との接続**: `id-token.ts` / `request-object.ts` はどちらも
  「候補選択 → import → verify」の同じ形をしているので、共有ヘルパ
  （例: `selectVerificationKeys(jwks, header, acceptedAlgs)`）へ寄せるのは自然。
  `packages/core/src/index.ts` は既にステップ関数を個別 export する設計なので、
  共有ヘルパの export も既存方針と整合する。
- **利用者・開発者・運用者のメリット**: 利用者は手元の JWKS をそのまま登録できる。
  開発者は鍵選択ロジックを 1 箇所で保守できる（PS256 / EdDSA 追加時の作業が半分になる）。
  運用者は失敗理由が切り分けられる。
- **実装しない場合に残るリスク**: `alg` の無い JWKS を使う利用者が原因不明の検証失敗に遭遇し続ける。
  さらに、鍵ポリシー拡張（PS256）を入れたときに 2 経路の挙動が割れる潜在バグが残る。

## 7. 実装方針の候補（最終判断は人間が行う）

### 方針A: `alg` 欠落を許容し、JWS ヘッダの `alg` から import パラメータを導出する（推奨検討）

- `extractAlgorithmParamsFromJwk(jwk, headerAlg?)` のように、JWS ヘッダ側の `alg` を
  フォールバックとして受け取れるようにする。`jwk.alg` があればそちらを優先し、
  食い違えば従来どおり拒否する（ダウングレード防止は維持）。
- `validateIdTokenHint` の `jwks.keys.filter((k) => k.alg === headerAlg)` を
  「`k.alg` が無いか `headerAlg` と一致する鍵」に緩める。
- 長所: 仕様適合な JWK Set が動く。既存の `alg` あり JWK の挙動は不変（後方互換）。
- 短所: 「`alg` の無い鍵は何にでも使える」ように見えるため、受け入れ `alg` 集合による
  事前フィルタが効いていることをコメント／テストで明示する必要がある。

### 方針B: 候補鍵選択を共有ヘルパへ抽出したうえで方針A を適用する

- 方針A に加えて `selectVerificationKeys()` を新設し、`id-token.ts` / `request-object.ts` の
  両方から呼ぶ。`kid` 一致優先 → `alg` 互換 → import 可能、という順序を 1 箇所に集約する。
- 長所: 非対称が構造的に解消され、PS256 / EdDSA 追加が 1 箇所で済む。
- 短所: リファクタ範囲が広がり、既存テスト（`id-token.test.ts` / `request-object.test.ts`）の
  期待値調整が要る。

### 方針C: `Jwk` 型を「発行用」と「受信検証用」に分ける

- `Jwk`（発行用・`alg`/`use` 必須）と `VerificationJwk`（受信用・`alg`/`use`/`kid` すべて optional）に分離。
- 長所: 型が実データを正しく表現する。利用者がフィールドを捏造しなくてよくなる。
- 短所: public API の型追加（破壊的ではないが export 面が増える）。
  `JwkSet` を受け取る既存シグネチャの調整が必要。

### 方針D: 現状維持＋ドキュメント化

- 「本 OP に登録する JWKS は `alg` を含めること」を README / CLI 生成コードコメントに明記する。
- 長所: 実装変更ゼロ。短所: 仕様適合な入力を拒否する状態が残り、Fidelity の主張が弱まる。

### 判断材料

- 方針A は単独でも成立し、後方互換。方針B/C は品質は上がるが変更面が広い。
- `tasks/p2-signing-alg-ps256.md`（PS256 追加）が控えているため、**方針B を先に入れると
  PS256 の作業量が減る**。逆に PS256 を先に入れると、非対称な 2 箇所を両方直すことになる。
  順序を人間が決める価値がある。
- 方針C は `RELEASE-v0.x-scope.md` の「public API を増やしすぎない」方針と要すり合わせ。

## 8. タスク案

- [ ] 方針（A / A+B / A+C / D）を決定する
- [ ] （TDD）`id-token.test.ts` に先行テストを追加:
  - [ ] `alg` を持たない RSA JWK（`kid` あり）で署名した `id_token_hint` が検証を通る
  - [ ] `alg` を持たない RSA JWK（`kid` なし）でも検証を通る
  - [ ] `alg` を持つ JWK で JWS ヘッダ `alg` と食い違う場合は従来どおり拒否される（回帰固定）
  - [ ] `kty=EC` / `crv=P-256` の JWK に `RS256` ヘッダの JWS を提示した場合は拒否される
- [ ] （TDD）`request-object.test.ts` に同等のテストを追加（`kid` 有無・`alg` 有無の 4 通り）
- [ ] `extractAlgorithmParamsFromJwk` に JWS ヘッダ `alg` のフォールバック引数を追加し、
      `jwk.alg` があるときは一致検証を維持する
- [ ] （方針B 採用時）候補鍵選択を共有ヘルパへ抽出し、両経路から呼ぶ
- [ ] （方針C 採用時）受信検証用の JWK 型を分離し、`alg` / `use` / `kid` を optional にする
- [ ] `request-object.ts` の `catch { continue }` で握り潰している import 失敗を、
      少なくとも `error_description` レベルで区別できるようにするか判断する
- [ ] `study-material/jws-algorithm-policy-and-alg-none-defense.md` の受け入れ alg 集合との整合を確認する
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test` がパス

## 関連トピック

- 📌 `study-material/inbound-jws-verification-crit-and-alg-binding.md` — 受信 JWS の**危険な入力の拒否**。
  本ファイルは逆に**正当な入力の受理**を扱う差分。
- 📌 `study-material/jws-algorithm-policy-and-alg-none-defense.md` — 受け入れ `alg` 集合のポリシー。
  本ファイルの緩和はこのポリシーの内側でのみ行う前提。
- 📌 `tasks/p2-signing-alg-ps256.md` — 鍵ポリシー拡張。本トピックの方針B を先行させると作業が減る依存関係。
