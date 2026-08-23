# Refresh で再発行する ID Token の `auth_time` 鮮度と、初回リクエストの `max_age` 契約

## ステータス

🟡 Medium（仕様間の緊張関係 / OP 側の支援手段の不在）/ 未着手

## 1. このトピックで確認したいこと

OIDC Core 1.0 には、refresh 経路で正面から緊張関係に立つ 2 つの規定がある。

- **§3.1.2.1（`max_age`）**: 「End-User が最後に能動的に認証されてからの経過可能時間」を指定する。
  経過時間がこれを超える場合、OP は **能動的な再認証を試みなければならない**。
- **§12.2（Successful Refresh Response）**: refresh で ID Token を返す場合、
  `auth_time` は **初回認証の時刻**を表さなければならない（再発行時刻ではない）。

`refresh_token` grant はバックチャネルであり、**OP がユーザを再認証する手段が存在しない**。
そのため OP は §12.2 に従って「古い `auth_time`」を載せた ID Token を返し続けることになる。

本リポジトリの生成 OP は、refresh のたびに（`openid` scope があれば）
**無条件に ID Token を再発行し、保存済みの初回 `authTime` をそのまま載せる**。
初回認可リクエストで `max_age` が指定されていたかどうかは、この判断に一切影響しない。
そもそも **`max_age` は refresh token に永続化されていない**ため、影響させることができない。

確認したいのは次の 3 点。

1. この挙動は §12.2 準拠として正しいのか、それとも §3.1.2.1 の契約を空洞化しているのか
2. `max_age` を要求したクライアントが refresh 経由で「鮮度の切れた ID Token」を
   受け取り続ける状況に、OP 側が提供すべき支援はあるのか
3. `max_age` / `default_max_age` を refresh token に永続化する価値があるか

> 重複回避:
> - `auth_time` を refresh で保持すること自体（§12.1 / §12.2）は
>   `study-material/id-token-auth-time-conditional-requirement.md` および
>   `tasks/done/p0-refresh-acr-amr-persistence.md` が扱う。
>   本ファイルは「保持は正しく実装されている。その**鮮度**をどう扱うか」という差分に限る。
> - `max_age` のパース厳格化は `tasks/p3-max-age-decimal-integer-strictness.md`、
>   `max_age=0` の境界は `tasks/done/p2-max-age-zero-reauthentication-boundary.md`、
>   `default_max_age` のフォールバックは `tasks/done/p2-client-default-max-age-fallback.md`。
>   いずれも **authorization_code 経路の話**であり、refresh 経路は対象外。
> - refresh で `nonce` を落とす判断は `study-material/done/refresh-id-token-nonce-omission.md`。
>   §12.2 の保持対象クレーム一覧はそちらで確定済みなので、本ファイルでは再掲しない。
> - refresh 時の scope / claims コンテキストの非保持は
>   `study-material/refresh-grant-claims-context-not-preserved.md`（`max_age` には言及なし）。

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 OIDC Core 1.0 §3.1.2.1 — `max_age`

> Maximum Authentication Age. Specifies the allowable elapsed time in seconds since the
> last time the End-User was actively authenticated by the OP.

経過時間が `max_age` を超える場合、OP は能動的に再認証を試みなければならない。
また `max_age` が使われた場合、返す ID Token には **`auth_time` クレームを含めなければならない**。

`max_age` は「このセッションの鮮度を保証してほしい」というクライアントからの要求であり、
**一回の認可リクエストに閉じた要求**なのか、**そのクライアントへ発行される ID Token 全般への要求**なのかは、
条文だけからは一意に読めない。ここが本トピックの曖昧点である。

### 2.2 OIDC Core 1.0 §12.2 — refresh 再発行 ID Token の `auth_time`

§12.2 が保持を要求するのは（列挙全体は
`study-material/done/refresh-id-token-nonce-omission.md` §3 を参照）、
本件に関係する部分だけを取れば:

- `auth_time` は、含める場合 **初回認証の時刻**を表さなければならない（再発行時刻ではない）。

つまり **「refresh で auth_time を更新して鮮度を偽装する」ことは明確に禁止されている**。
OP に残された選択肢は「古い `auth_time` のまま返す」か「ID Token を返さない」かの二択になる。

### 2.3 OIDC Core 1.0 §12 — refresh での ID Token は MAY

§12.2 は refresh のレスポンスについて「it might not contain an id_token」と述べる。
すなわち **refresh で ID Token を返さない選択は仕様上完全に正当**である。
これが本トピックの実装方針の候補を成立させる根拠になる。

### 2.4 OIDC Core 1.0 §3.1.3.7 — 検証責務はクライアント側にもある

ID Token Validation の手順には、`auth_time` が要求された場合
（個別要求または `max_age` の使用による）、
クライアントは `auth_time` を確認し、経過しすぎていれば再認証を要求すべき（SHOULD）
という趣旨の規定がある。

したがって **「古い `auth_time` を返すこと自体は OP の違反ではない」**。
鮮度判定の最終責任はクライアントにある。
本トピックは「OP が違反しているか」ではなく
「OP が利用者に提供すべき制御手段が欠けていないか」という設計品質の問題である。

## 3. 参照資料

- OpenID Connect Core 1.0 §3.1.2.1 Authentication Request（`max_age` の定義。
  超過時に OP は能動的再認証を試みる。`max_age` 使用時は ID Token に `auth_time` 必須）
  — https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest
- OpenID Connect Core 1.0 §2 ID Token（`auth_time` の定義）
  — https://openid.net/specs/openid-connect-core-1_0.html#IDToken
- OpenID Connect Core 1.0 §12.1 Refresh Request / §12.2 Successful Refresh Response
  （再発行 ID Token のクレーム要件。`auth_time` は初回認証時刻。`id_token` は MAY）
  — https://openid.net/specs/openid-connect-core-1_0.html#RefreshTokens
- OpenID Connect Core 1.0 §3.1.3.7 ID Token Validation
  （`max_age` 使用時、クライアントは `auth_time` を確認し再認証を要求すべき）
  — https://openid.net/specs/openid-connect-core-1_0.html#IDTokenValidation
- OpenID Connect Dynamic Client Registration 1.0 §2 Client Metadata
  （`default_max_age` / `require_auth_time`）
  — https://openid.net/specs/openid-connect-registration-1_0.html#ClientMetadata

## 4. 現在の実装確認

### 4.1 authorization_code 経路では `max_age` が正しく機能している

`packages/core/src/authorization-request.ts` の `resolveMaxAge()` が
リクエストの `max_age` とクライアント登録の `default_max_age` を解決し、
`ValidatedAuthorizationRequest.maxAge` として返す。
再認証判定（`requiresReauthentication`）は認可トランザクション側で行われる。

この経路は既存タスク群で継続的に整備されている
（`tasks/p3-max-age-decimal-integer-strictness.md` /
`tasks/done/p2-max-age-zero-reauthentication-boundary.md` /
`tasks/done/p2-client-default-max-age-fallback.md`）。

### 4.2 refresh token に `max_age` は保存されない

`packages/core/src/token-request.ts` の `RefreshTokenInfo`（L173-）が保持するのは:

`subject` / `clientId` / `scope` / `expiresAt` / `used` / `grantId` / `iat` /
`originalIssuedAt` / `issuer` / `lastUsedAt` / `audience` / `authTime` /
`nonce` / `acr` / `amr` / `azp`

**`maxAge` に相当するフィールドは存在しない。**
`authTime`（初回認証時刻）は保存されるが、
「そのとき何秒以内の鮮度が要求されていたか」は失われる。

### 4.3 refresh では無条件に ID Token を再発行する

`packages/cli/src/frameworks/hono/templates.ts` のトークンルート:

```
// OIDC Core 1.0 §12: refresh_token grant でも id_token は MAY。
// openid scope を持つ場合は §12.1 に従い初回認証時と同じ auth_time / acr / amr / azp で再発行する。
let idToken: string | undefined;
...
if (validatedRequest.scope.includes('openid')) {
```

判定条件は **`openid` scope の有無だけ**である。
`authTime` の経過時間は参照されない。

`authTime` の供給元:

```
} else {
  // refresh_token grant
  ...
  subject = validatedRequest.subject;
  authTime = validatedRequest.authTime;   // 初回認証時刻（§12.1 準拠）
  nonce = undefined;
}
```

`buildIdTokenPayload` は `authTime !== undefined` なら `auth_time` を載せる
（`packages/core/src/token-response.ts` L477-479）。
生成 OP は refresh token 発行時に `authTime` が無ければ発行自体を中断する実装なので、
**refresh 再発行 ID Token には常に `auth_time` が載る**。

### 4.4 結果として起きること

クライアントが `max_age=300`（5 分以内の認証を要求）で認可を受け、
`offline_access` で refresh token を取得したとする。

| 時刻 | 出来事 | 返る ID Token の `auth_time` | クライアントが `max_age=300` で検証すると |
|---|---|---|---|
| t=0 | 認可コード交換 | t=0 | ✅ 鮮度内 |
| t=3000（50 分後） | refresh | **t=0** | ❌ 鮮度切れ（2700 秒超過） |
| t=86400（24 時間後） | refresh | **t=0** | ❌ 鮮度切れ |

OP は §12.2 に従い正しく振る舞っているが、
**`max_age` を指定したクライアントに対して、鮮度契約を満たさない ID Token を
無限に発行し続ける**状態になる。

## 5. 現在の実装との差分

### 満たしていること

- ✅ §12.2 の「`auth_time` は初回認証時刻」を正しく実装している。
  鮮度を偽装する（再発行時刻を `auth_time` に入れる）ような違反は無い。
- ✅ `max_age` 使用時に ID Token へ `auth_time` を含める要件（§3.1.2.1）を、
  refresh 経路でも結果的に満たしている（常に含めるため）。
- ✅ authorization_code 経路の `max_age` / `default_max_age` 処理は整備済み。
- ✅ **仕様違反は存在しない。** 鮮度判定の最終責務は §3.1.3.7 によりクライアント側にある。

### 不足している可能性があること

- 🟡 **`max_age` が refresh token に永続化されていない**ため、
  OP 側で鮮度ポリシーを適用したくてもできない。
  `acr` / `amr` / `authTime` / `azp` は §12.1 / §12.2 のために永続化されているのに、
  それらの鮮度を規定した `max_age` だけが落ちている、という非対称がある。
- 🟡 **OP に鮮度ポリシーの注入点が無い**。
  「`max_age` を超えたら refresh で ID Token を返さない」という運用は
  §12（`id_token` は MAY）により完全に正当だが、
  利用者がそれを選ぶ手段が生成コードにも core にも無い。
- 🟢 **ドキュメント上の注意喚起が無い**。
  `max_age` を使う PoC 開発者が「refresh すると鮮度が保証されない」ことに
  気づける記述が README / 生成コードコメントに無い。

### 実装はあるが仕様上の確認が必要なこと

- 🟡 **`max_age` の適用範囲の解釈**。
  「一回の認可リクエストに対する要求」と読むなら現状で完全に正しい。
  「そのクライアントへの ID Token 全般に対する要求」と読むなら、
  refresh でも何らかの配慮が要る。
  **条文からは一意に決まらない**ため、これは実装が選ぶ設計判断である。
  この曖昧さ自体を不明点として記録しておく価値がある。
- 🟡 `require_auth_time`（クライアント登録メタデータ）との関係。
  `study-material/done/client-default-max-age-and-require-auth-time.md` が
  authorization_code 経路を扱っているが、refresh 経路での意味は未整理。

### セキュリティ上、改善した方がよいこと

- 🟡 `max_age` の典型的な用途は「機微操作の直前に新しい認証を要求する」ことである。
  クライアントが §3.1.3.7 の SHOULD を実装し損ねると、
  **古い認証に基づく ID Token を「新鮮」と誤認する**。
  OP 側で ID Token を返さない選択肢を提供できれば、この誤りを構造的に防げる
  （fail-safe をクライアント実装の品質に依存させない）。

### 相互運用性の観点で改善した方がよいこと

- 🟢 現状の挙動は主要 OP と整合的であり、相互運用上の問題は無い。
  むしろ「refresh で ID Token を返さない」を**既定**にすると、
  ID Token を期待するクライアントを壊すため、既定変更は慎重であるべき。

### Basic OP として提供する上で確認すべきこと

- 🟢 OIDF Conformance Suite の Basic OP プロファイルは
  「refresh 再発行 ID Token の `auth_time` が初回認証時刻であること」を検証する側であり、
  **現状の実装はその検証を通る**。本トピックは認定の合否に影響しない。

## 6. 改善・追加を検討する理由

- **Fidelity（仕様の忠実さ）**: 本リポジトリは仕様準拠を第一の軸に置く。
  §3.1.2.1 と §12.2 が緊張関係にあるという事実そのものが、
  「OIDC を検証するためのライブラリ」として説明すべき論点である。
  現状はどちらの条文も個別には満たしているが、**両者の関係が意図的に整理された形跡が無い**。
- **PoC 検証ツールとしての価値**: 「`max_age` を使ったセッション鮮度制御が、
  refresh を含めた運用で本当に成立するか」は、
  金融・医療系の PoC で頻出する検証項目である。
  現状ではその検証ができない（OP 側に選択肢が無いため、常に一方の挙動しか試せない）。
- **導入しやすさ**: `RefreshTokenInfo` に optional な `maxAge?: number` を足し、
  生成コードの ID Token 発行条件に 1 つ判定を足すだけで済む。
  **`acr` / `amr` / `authTime` を永続化した既存の先例（`tasks/done/p0-refresh-acr-amr-persistence.md`）が
  そのまま実装パターンとして使える。**
- **既存実装との接続**: `ValidatedAuthorizationRequest.maxAge` はすでに存在するので、
  認可コード → refresh token への引き回し経路に 1 フィールド足すだけで届く。
- **利用者・運用者へのメリット**:
  - クライアント実装の品質に依存せず、鮮度契約を OP 側で担保できる。
  - 「refresh で ID Token が返らない」を試せることで、
    クライアント側の再認証フロー実装を PoC 段階で検証できる。
- **実装しない場合に残る制約・リスク**:
  - `max_age` を指定したクライアントが、鮮度切れの ID Token を受け取り続ける。
  - §3.1.3.7 の SHOULD を実装しないクライアントが、古い認証を新鮮と誤認する。
  - 「`max_age` は refresh を跨いでは効かない」という重要な性質が、
    どこにも記述されないまま残る。

## 7. 実装方針の候補（最終判断は人間）

### 方針A: `max_age` を永続化し、超過時は refresh で ID Token を返さない（オプトイン）

- `RefreshTokenInfo` に `maxAge?: number` を追加し、認可コードから引き継ぐ。
- 設定（例: `enforceMaxAgeOnRefresh`、既定 `false`）が有効なときのみ、
  `now - authTime > maxAge` なら ID Token を省略してアクセストークンだけ返す。
- §12（`id_token` は MAY）により完全に正当。
- メリット: 既定の挙動を変えないまま、鮮度契約を OP 側で担保する選択肢を提供できる。
  §12.2 の `auth_time` 規定とも衝突しない。
- デメリット: ID Token を前提とするクライアントは、
  設定を有効にした OP に対して「ある日突然 `id_token` が来なくなる」挙動に備える必要がある
  （仕様上は正当だが、実装していない RP は多い）。

### 方針B: `max_age` を永続化し、超過時は refresh 自体を拒否する

- `invalid_grant` を返し、クライアントに認可フローのやり直しを強制する。
- メリット: 鮮度契約が最も強く担保される。クライアント側の分岐が単純になる
  （エラー → 再認可、という既存の経路に乗る）。
- デメリット: **アクセストークンの更新まで止まる**ため、
  `max_age` を「初回のみの要求」と解釈しているクライアントを壊す。
  §12.1 に refresh を拒否する根拠は無く、仕様的な後ろ盾が方針 A より弱い。

### 方針C: 判定を利用者へ委譲する（コールバック注入）

```ts
/** refresh で ID Token を再発行するか。false なら id_token を省略する。 */
shouldIssueIdTokenOnRefresh?: (context: {
  subject: string;
  clientId: string;
  authTime: number;
  maxAge?: number;
  now: number;
}) => boolean | Promise<boolean>;
```

- 本リポジトリの resolver / callback 注入パターン
  （`AcrResolver` / `OfflineAccessGrantedCallback` 等）に揃う。
- メリット: 鮮度以外のポリシー（アカウント状態の再確認など）も同じ口で表現できる。
  `max_age` 永続化は「コールバックへ渡す材料」として位置づけられる。
- デメリット: 既定実装を用意しないと現状と何も変わらない。
  API 表面が増える。

### 方針D: 現状維持＋明文化

- 実装は変えず、次を記述する。
  - `max_age` は authorization_code 経路の要求であり、refresh を跨いでは適用されないこと
  - refresh 再発行 ID Token の `auth_time` は §12.2 に従い初回認証時刻であること
  - 鮮度判定は §3.1.3.7 によりクライアントの責務であること
- メリット: 変更ゼロ。仕様違反が無い以上、正確な説明だけでも価値がある。
- デメリット: PoC で鮮度制御を検証したい利用者の要求は満たせない。

### 判断材料

- **仕様違反は存在しない**ため、本件は「欠陥修正」ではなく「機能の追加」として評価するのが正確である。
  優先度を過大評価しないよう注意が要る。
- 方針 A / B / C はいずれも **`max_age` の永続化**を前提とする。
  永続化だけを先に入れておけば（無害・後方互換）、
  ポリシーの選択は後から決められる。**段階的導入がしやすい構造**になっている。
- 方針 A は §12 の MAY に素直で、既定を変えないため導入リスクが最も低い。
- 方針 B は仕様的な後ろ盾が弱く、既存クライアントへの影響が大きい。
- 方針 D を採る場合でも、`max_age` が refresh を跨がないという性質は
  README か生成コードコメントのどこかに書いておく価値が高い
  （利用者がこれを知らずに鮮度制御を設計すると、PoC の結論を誤る）。

## 8. タスク案

- [ ] 方針 A / B / C / D のどれを採るかを人間が判断する
- [ ] 方針にかかわらず先行して実施できるもの:
  - [ ] `max_age` が refresh を跨いで適用されないことを、
        生成コードの refresh 分岐コメントと README に明記する
  - [ ] 現在の挙動（`max_age` 指定後の refresh で古い `auth_time` を持つ ID Token が返る）を
        契約テストとして固定し、意図した挙動であることを可視化する
- [ ] 方針 A / B / C 採用時の共通作業:
  - [ ] `RefreshTokenInfo` に `maxAge?: number` を追加する
  - [ ] `ValidatedAuthorizationRequest.maxAge` → 認可コード → refresh token の
        引き回し経路を実装する（`acr` / `amr` の永続化経路が先例）
  - [ ] rotation 時に `maxAge` を引き継ぐことを確認する
- [ ] 方針 A 採用時:
  - [ ] `enforceMaxAgeOnRefresh`（既定 `false`）を生成コードの config に追加する
  - [ ] 有効時、`now - authTime > maxAge` なら `id_token` を省略する分岐を実装する
  - [ ] 省略時もアクセストークン・refresh token の rotation は通常どおり行うことを確認する
- [ ] テスト要件:
  - [ ] `max_age` 未指定の refresh では従来どおり ID Token が返ることを回帰テストで固定する
  - [ ] `max_age` 指定 + 鮮度内の refresh で ID Token が返り、`auth_time` が初回値であることを固定する
  - [ ] `max_age` 指定 + 鮮度超過の refresh で、方針に応じた結果
        （既定: ID Token あり / 有効時: `id_token` フィールド自体が無い）を固定する
  - [ ] `conformance.test.ts` に上記を追加し、§12.2 の `auth_time` 規定を破らないことを確認する
- [ ] `study-material/done/client-default-max-age-and-require-auth-time.md` の
      `require_auth_time` が refresh 経路で持つ意味を整理し、必要なら追記する
