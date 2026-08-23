# 複数署名鍵を公開する場合の発行 JWT に対する `kid` 必須化（ID Token / 署名付き UserInfo / JWT Access Token）

## ステータス

🟡 Major（相互運用性・Conformance）/ 未着手

## 1. このトピックで確認したいこと

OP が JWKS に **2 つ以上の署名鍵を同時公開**している（鍵ローテーション中・RS256/ES256 の alg 併存など）状況で、
発行する署名付き JWT（ID Token / 署名付き UserInfo / JWT Access Token）の JOSE Header に
**検証側が鍵を一意に選べる `kid` が必ず含まれているか**を確認する。

具体的には次の 2 点が論点:

1. 現在 `kid` は全署名経路で **optional**（指定されたときだけ Header に載る）であり、
   「JWKS に複数鍵があるのに発行 JWT に `kid` が無い」という不整合をライブラリが**検知・防止していない**。
2. 検証側（RP）が複数鍵から正しい鍵を選べないと、ライブラリ実装によっては
   「全鍵で総当たり検証」または「検証拒否」となり、**サイレントに ID Token 検証が壊れる / 相互運用性が落ちる**。

### 既存の関連ファイルとの差分（重複回避）

- `study-material/signing-key-rotation-operations.md`:
  鍵ローテーションの**運用フロー（時間軸）**・`kid` の命名規則・リタイア基準・キャッシュ TTL を扱う。
  → 本ファイルは「**発行時に `kid` を必ず載せる／載っていなければ起動・発行を失敗させる**」という
  **コード上の不変条件（enforcement）の差分**に絞る。運用手順の説明は繰り返さない。
- `study-material/jwks-endpoint-comprehensive.md`:
  JWKS の**構造**（`kid` 重複排除・`use`/`alg`）を扱う。鍵公開側の話。
  → 本ファイルは**発行 JWT 側の Header `kid`** と JWKS 側 `kid` の**整合保証**に絞る。
- `tasks/done/T-022-add-sign-keys.md`:
  複数鍵登録と `id_token_signed_response_alg` による鍵選択を実装済み。
  T-022 経由（`selectSigningKeyByAlg()` → `SigningKey.keyId`）では `kid` は正しく載る。
  → 本ファイルは **T-022 経路を通らない単一鍵 / 低レベル core API 直叩き / `keyId` 未設定**のケースで
  ガードが無い差分を扱う。

## 2. 関連する仕様・基準

> ⚠️ 注記: 本環境からは openid.net / rfc-editor.org への直接アクセスが 403 で不可だったため、
> 以下の **section 番号と規範レベル（SHOULD/RECOMMENDED）は確実**だが、
> **逐語引用は一次資料での再確認を推奨**する（§5 のタスク案に再確認チェックを含めた）。

- **OpenID Connect Core 1.0 §10.1 Signing / §10.1.1 Rotation of Asymmetric Signing Keys**
  - OP は署名鍵を `jwks_uri` で公開し、署名 JWT の JOSE Header に `kid`（Key ID）を **付与すべき（SHOULD/RECOMMENDED）**。
  - 鍵ローテーション時、検証側は **`kid` を使って JWK Set の中から該当鍵を選ぶ**ことが前提。
  - つまり「公開鍵が 1 つだけ」なら `kid` 無しでも一意に決まるが、
    **複数鍵を公開した瞬間に `kid` が無いと鍵選択が曖昧**になる。
- **RFC 7515 (JWS) §4.1.4 `kid` Header Parameter**
  - `kid` は「どの鍵で署名したかを示すヒント」。**Use of this Header Parameter is OPTIONAL**（JWS 単体では任意）。
  - すなわち規範レベルとしては「MUST」ではなく、**複数鍵運用時の実務上の必須**である点を正確に押さえる。
- **RFC 7517 (JWK) §4.5 `kid` Parameter**
  - `kid` は「特定の鍵を一致させるため」に使い、**鍵ロールオーバー時に JWK Set 内の複数鍵から選ぶ**典型用途。
  - JWK Set 内で `kid` を使う場合、各鍵は **distinct な `kid` を持つべき（SHOULD）**。
- **OpenID Connect Conformance Profiles（Basic OP）**
  - OIDF の Basic OP テストプランには、鍵選択の健全性を確認する観点（通称 `OP-IDToken-kid` 相当）が含まれ、
    **複数鍵を公開する OP は発行 ID Token に `kid` を載せること**が期待される。
  - Basic OP の**既定（単一 RS256 鍵）運用では必須ではない**が、
    Fidelity（Conformance 準拠をシグナルにする）という本リポジトリの差別化軸を考えると、
    鍵ローテーション／複数 alg を「使った瞬間に壊れない」ことを保証したい。

要点（事実と推測の区別）:

- **事実**: 規範レベルでは `kid` は JWS では OPTIONAL、OIDC Core では SHOULD。よって「常に MUST」ではない。
- **事実**: 複数鍵を JWK Set に公開した場合、`kid` が無いと検証側の鍵選択は曖昧になる（RFC 7517 §4.5 の用途定義より）。
- **判断**: したがって本リポジトリでは「**複数鍵公開時は発行 JWT に `kid` を載せることを実装上の不変条件にする**」のが
  仕様の趣旨・相互運用性・Conformance のいずれにも沿う。

## 3. 参照資料

- OIDC Core 1.0 §10.1 / §10.1.1 Rotation of Asymmetric Signing Keys:
  https://openid.net/specs/openid-connect-core-1_0.html#RotateSigKeys
- RFC 7515 (JWS) §4.1.4 `kid`:
  https://datatracker.ietf.org/doc/html/rfc7515#section-4.1.4
- RFC 7517 (JWK) §4.5 `kid`:
  https://datatracker.ietf.org/doc/html/rfc7517#section-4.5
- OpenID Connect Conformance Profiles（Basic OP テストプラン）:
  https://openid.net/certification/conformance-testing-for-openid-connect/
- 既存運用ガイド（重複回避のための内部参照）: `study-material/signing-key-rotation-operations.md`

## 4. 現在の実装確認

### `kid` を載せる経路（optional 扱い）

- `packages/core/src/id-token.ts` `generateIdToken()`:
  ```ts
  const header: Record<string, string> = { alg: getJwaAlgorithm(privateKey), typ: 'JWT' };
  if (keyId) {
    header.kid = keyId;   // ← keyId が無ければ kid は載らない
  }
  ```
- `packages/core/src/userinfo.ts` `generateUserInfoJwt()`: 同様に `if (keyId) header.kid = keyId;`。
- `packages/core/src/access-token.ts`（JWT Access Token）: 同様に `kid` は optional。
- `packages/core/src/signing-key.ts`:
  - `SigningKey.keyId: string` は **必須フィールド**（型上は常に存在）。
  - `selectSigningKeyByAlg()` は `SigningKey` を返すため、その `keyId` を使えば `kid` は確実に取れる。

### 実際の発行フロー

- `packages/sample/src/oidc-provider/routes/token.ts`:
  - 複数鍵経路（T-022）: `selectSigningKeyByAlg(idTokenSigningKeys, requestedAlg)` →
    `idTokenKeyId = selectedIdTokenKey.keyId` を `generateTokenResponse` に渡す。**この経路では `kid` が載る。**
  - アクセストークン署名鍵: `keyId = c.get('keyId')`。**`c.get('keyId')` が未設定なら `undefined`** → `kid` 無しになりうる。
- `packages/core/src/token-response.ts`:
  - `keyId?: string` / `idTokenKeyId?: string` はいずれも optional。`idtKid = idTokenKeyId ?? keyId`。
  - どちらも未設定なら ID Token に `kid` が載らない。

### ガードの有無

- **JWKS に複数鍵があるか**と**発行 JWT に `kid` があるか**を突き合わせて検証する箇所は**存在しない**。
- `assertHasRs256Key()` は「RS256 鍵が 1 つ以上あるか」は見るが、`kid` 整合は見ない。
- 起動時にも発行時にも「複数鍵公開なのに `kid` 無し発行」を弾く不変条件は無い。

## 5. 現在の実装との差分

満たしていること:

- 🟢 T-022 の複数 alg 鍵選択経路（`selectSigningKeyByAlg` → `SigningKey.keyId`）を使う限り `kid` は載る。
- 🟢 `SigningKey.keyId` は必須型なので、鍵プロバイダ実装者は `kid` を必ず持つ。
- 🟢 JWKS 側は `kid` を重複排除して公開できる（`jwks.ts`）。

不足／曖昧：

- 🟡 **enforcement 不在**: 「JWKS に 2 つ以上の鍵 → 発行 JWT に JWKS に存在する `kid` を MUST」という不変条件が無い。
  - 単一鍵の sample でも `c.get('keyId')` を設定し忘れると `kid` 無しで発行されうる。
  - core を**ロジック層として直接使う高度ユースケース**で、`generateIdToken({ payload, privateKey })`（`keyId` 省略）を
    呼びつつ JWKS に複数鍵を公開すると、ライブラリは何も警告せず壊れた構成を許す。
- 🟡 **相互運用性リスク**: `kid` 無し ID Token を受け取った RP が、JWKS の複数鍵から鍵を選べず検証失敗 or 総当たり。
  検証ライブラリ依存でサイレントに壊れる（テストでは単一鍵なので気付きにくい）。
- 🟡 **Conformance リスク**: 複数鍵で Basic OP を流すと `OP-IDToken-kid` 相当の観点で落ちうる。
- 🟢 **逆に単一鍵の既定運用には影響しない**ため、破壊的変更ではなく「複数鍵時のみ厳格化」で対応可能。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: 鍵ローテーションは本番運用で必ず通る道で、失敗すると**全クライアントの ID Token 検証が一斉に壊れる**。
  この不整合を**起動時 or 発行時に fail-fast** させれば、サイレント障害を構成ミスの段階で潰せる。
- **Basic OP として必要か / 拡張か**:
  - 単一 RS256 鍵の最小 Basic OP では**必須ではない**。
  - ただし鍵ローテーション・複数 alg は「本番志向」ユーザーが必ず使うため、
    **Basic OP を「複数鍵でも通る」状態に保つための Fidelity 施策**として価値が高い。
- **導入しやすさ**: `SigningKey.keyId` が既に必須型で、複数鍵経路は既に `kid` を載せている。
  追加するのは「複数鍵なのに `kid` 未指定／JWKS に無い `kid`」を弾くガードだけで、既存正常系を壊さない。
- **既存実装との接続**: `assertHasRs256Key()` と同じ「起動時アサーション」の枠組みに
  `assertKidPresenceForMultiKey()` 系を足す形が自然。発行時ガードは `generateIdToken` 直前に挟める。
- **利用者メリット**: 鍵ローテーションを「試したらハマる」OSS にしない。構成ミスが本番ではなく起動時に出る。
- **実装しない場合のリスク**: 複数鍵運用者がサイレントに相互運用性を失う。Conformance（複数鍵）で落ちる。

## 7. 実装方針の候補

> 最終判断は人間が行う。以下は判断材料。

### 方針A（起動時アサーション中心 / 推奨ベース）

- core に「登録鍵集合に 2 件以上ある場合、各 `SigningKey.keyId` が非空かつ JWK Set 内で distinct」を検証する
  `assertKidStrategyConsistent(keys)` を追加し、`buildProviderMetadata` / 鍵プロバイダ初期化時に呼ぶ。
- メリット: 構成ミスが**起動時**に出る。発行ホットパスに分岐を増やさない。
- 注意: core を低レベルで直叩きするユースケースは起動アサーションを通らないため、方針 B と併用が望ましい。

### 方針B（発行時ガード）

- `generateIdToken` / `generateUserInfoJwt` / JWT Access Token 発行に
  `requireKid?: boolean` オプション（複数鍵公開時に true を渡す）を追加し、true なのに `keyId` 未指定なら throw。
- もしくは、発行関数に「公開中の JWKS の鍵数」を渡せるようにし、>1 かつ `keyId` 未指定で throw。
- メリット: core 直叩きでもガードが効く。
- 注意: 引数が増える。既定 false で後方互換を保つ設計が必要。

### 方針C（sample / CLI テンプレ側のみで担保）

- `selectSigningKeyByAlg()` の結果 `keyId` を**常に**発行関数へ渡すよう CLI テンプレを修正し、
  `c.get('keyId')` が `undefined` になり得る経路を排除する。
- メリット: core の I/F を変えない。
- 注意: core をライブラリとして使う利用者は保護されない（テンプレ利用者のみ保護）。

判断材料:

- 「Fidelity を最優先」なら A + B（起動と発行の二重ガード）。
- 「最小変更で sample/CLI 利用者だけ守る」なら C。
- core の責務範囲（純粋関数に副作用的アサーションをどこまで持たせるか）と相談。

## 8. タスク案

- [ ] 一次資料（OIDC Core §10.1.1 / RFC 7515 §4.1.4 / RFC 7517 §4.5）の**逐語**を再確認し、本ファイルの規範レベル記述を確定
- [ ] OIDF Basic OP テストプランで `kid` を検証するテスト名・条件（複数鍵時の期待挙動）を確認し本ファイルに追記
- [ ] 方針 A / B / C のどこまで採るかを人間が判断
- [ ] 方針 A 採用時:
  - [ ] `assertKidStrategyConsistent(keys)` を `signing-key.ts` に追加（>1 件で `keyId` 非空・distinct を検証）
  - [ ] `buildProviderMetadata` または鍵初期化経路から呼ぶ
  - [ ] テスト: 複数鍵で `keyId` 重複 / 空 → 起動時 throw、単一鍵 → 通過
- [ ] 方針 B 採用時:
  - [ ] `generateIdToken` / `generateUserInfoJwt` / JWT Access Token に `requireKid` 系オプション追加（既定 false で後方互換）
  - [ ] テスト: `requireKid=true` かつ `keyId` 未指定 → throw、指定あり → `kid` が Header に載る
- [ ] 方針 C 採用時:
  - [ ] CLI/sample で発行関数へ `keyId` を常に渡すよう修正（`c.get('keyId')` の undefined 経路を排除）
  - [ ] テスト: 複数鍵テンプレ生成で全発行 JWT に `kid` が載ること
- [ ] いずれの方針でも: 「複数鍵 JWKS + 発行 ID Token の `kid` が JWKS の鍵に一致する」結合テストを追加
