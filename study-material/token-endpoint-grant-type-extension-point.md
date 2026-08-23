# Token Endpoint に grant_type の拡張点が無く、拡張グラントは core を迂回するしかない

## ステータス

🟠 High（拡張性 / 保守性）/ 未着手

## 1. タイトル

`packages/core` の Token Endpoint が `authorization_code` と `refresh_token` の 2 値をハードコードしており、新しい grant_type を core の検証パイプラインに載せる拡張点が存在しない点の確認。実装済みの device_code / token-exchange は、生成コードが core より手前で横取りする形でしか成立していない。

## 2. このトピックで確認したいこと

`validateGrantTypeSupported` は戻り値の型が `'authorization_code' | 'refresh_token'` であり、それ以外の値をすべて `unsupported_grant_type` に落とす。
一方 experimental は既に 2 つの拡張グラントを持ち、CIBA（`tasks/experimental/ciba/`）が次に控えている。
現状これらは、生成コードのルートハンドラが core を呼ぶ前に自前で分岐して応答を返し切る形で実装されている。

確認したいのは次の三点である。

- OAuth 2.0 / OAuth 2.1 が grant_type の拡張をどう規定しており、認可サーバに何を課しているか
- 迂回方式で成立しているとき、core が担う検証（クライアント認証、クライアント別 grant 認可、エラー整形）のどこが各拡張グラントに再実装されているか
- 拡張点を core に置く場合と、迂回方式を明示的な契約として文書化する場合の得失

### 既存ファイルとの関係（重複回避）

| 論点 | 扱っているファイル |
|---|---|
| 削除されたグラント（implicit / password）の明示的拒否 | `study-material/done/oauth21-removed-grants-explicit-rejection.md`、`tasks/p2-removed-grants-explicit-rejection-tests.md` |
| クライアント登録 `grant_types` の強制と `unauthorized_client` | `study-material/done/client-metadata-enforcement.md`、`study-material/done/offline-access-grant-vs-client-grant-types-consistency.md` |
| `grant_type` と他パラメータの取り違え（parameter confusion） | `study-material/token-endpoint-grant-parameter-confusion.md` |
| Discovery の `grant_types_supported` 既定値と広告 | `study-material/done/discovery-grant-types-supported-implicit-default.md`、`tasks/p3-discovery-grant-types-implicit-default.md` |
| experimental 機能の Discovery 表現力 | `study-material/done/discovery-metadata-experimental-features-core-expressibility.md` |
| resolver / store 契約の一般論 | `study-material/resolver-and-store-contract.md` |
| CLI がフレームワーク非依存のハンドラを導出する仕組み | `study-material/cli-framework-portability-and-web-standard-handler.md` |

上記はいずれも「既知の grant_type をどう扱うか」を論じており、**core が知らない grant_type をどう載せるか**という構造の問題は扱っていない。
本ファイル固有の差分はその一点に限る。

## 3. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` §3.3 を参照する。

### 3.1 RFC 6749 §4.5 / §8.3（拡張グラント）

RFC 6749 §4.5 は、認可サーバが絶対 URI 形式の `grant_type` 値で追加のグラントタイプを定義してよいと定める。
§8.3 は、拡張グラントを IANA の OAuth Parameters レジストリへ登録する手続きを定める。
つまり grant_type は最初から**拡張されることを前提にした開いた集合**であり、`authorization_code` / `refresh_token` の 2 値に閉じるのは仕様の要求ではなく実装の選択である。

実際に本リポジトリが扱う拡張グラントは、いずれも URN 形式である。

- `urn:ietf:params:oauth:grant-type:device_code`（RFC 8628 §3.4）
- `urn:ietf:params:oauth:grant-type:token-exchange`（RFC 8693 §2.1）
- `urn:openid:params:grant-type:ciba`（CIBA Core §10.1）

### 3.2 RFC 6749 §5.2（エラーコードの切り分け）

- `unsupported_grant_type`：認可サーバがそのグラントタイプに対応していない
- `unauthorized_client`：認証済みクライアントがそのグラントタイプの使用を認可されていない
- `invalid_client`：クライアント認証の失敗

この 3 者の切り分けは grant_type ごとに変わらない。拡張グラントでも同じ判定が要る。

### 3.3 OAuth 2.1

OAuth 2.1 は password / implicit を削除するが、grant_type の拡張機構そのものは維持している。
未対応の grant_type に `unsupported_grant_type` を返す規定も RFC 6749 から変わらない。

## 4. 参照資料

- RFC 6749 The OAuth 2.0 Authorization Framework §4.5（Extension Grants） / §5.2 / §8.3 — https://www.rfc-editor.org/rfc/rfc6749
- RFC 8628 OAuth 2.0 Device Authorization Grant §3.4 — https://www.rfc-editor.org/rfc/rfc8628
- RFC 8693 OAuth 2.0 Token Exchange §2.1 — https://www.rfc-editor.org/rfc/rfc8693
- OpenID Connect CIBA Core 1.0 §10.1 — https://openid.net/specs/openid-client-initiated-backchannel-authentication-core-1_0.html
- IANA OAuth Parameters レジストリ（`grant_type` の登録値） — https://www.iana.org/assignments/oauth-parameters/

## 5. 現在の実装確認

### 5.1 core の閉じた分岐

`packages/core/src/token-request.ts`:

```ts
const DEFAULT_SUPPORTED_GRANT_TYPES = ['authorization_code', 'refresh_token'] as const;

export function validateGrantTypeSupported(
  grantType: string | undefined,
  supportedGrantTypes: string[] = [...DEFAULT_SUPPORTED_GRANT_TYPES],
): 'authorization_code' | 'refresh_token' {
  ...
  if (
    (grantType !== 'authorization_code' && grantType !== 'refresh_token') ||
    !supportedGrantTypes.includes(grantType)
  ) {
    throw new TokenError(
      TokenErrorCode.UnsupportedGrantType,
      `Unsupported grant_type: ${grantType}`
    );
  }
  return grantType;
}
```

`TokenRequestContext.supportedGrantTypes` は**絞り込みにしか使えない**。
リストに `urn:ietf:params:oauth:grant-type:device_code` を足しても、その前段の型比較で弾かれる。

`ValidatedTokenRequest` も `ValidatedAuthorizationCodeRequest | ValidatedRefreshTokenRequest` の 2 値の判別共用体であり、第 3 の grant を表現できない。

### 5.2 生成コードによる迂回

`packages/cli/src/frameworks/hono/templates.ts` の device grant 分岐には、迂回であることが明記されている。

> Dispatched right after client authentication and BEFORE core's `validateGrantTypeSupported`, which does not know the URN and would reject it with `unsupported_grant_type`. The branch answers the request itself and never falls through to the standard grants.

token-exchange も同じ構造を持つ。

> dispatch the token-exchange grant before core's `validateGrantTypeSupported` rejects the URN.

この結果、各拡張グラントの分岐は次を自前で持つ。

- 署名鍵の選択（`selectSigningKeyByAlg` の呼び出しとフォールバック、鍵不在時の `server_error` 応答）
- アクセストークン発行方式の切り替え（`createOpaqueAccessTokenIssuer` / `createJwtAccessTokenIssuer`）
- `aud` の合成（`buildAccessTokenAudience`）
- `Cache-Control: no-store` / `Pragma: no-cache` の付与
- リフレッシュトークンの発行と保存（device grant のみ）

device grant の ID Token 署名鍵選択のコードは、標準グラントのそれとほぼ同じ形が別変数名で複製されている（`deviceSelectedIdTokenKey` / `selectedIdTokenKey`）。

### 5.3 クライアント別 grant 認可

core の `validateClientGrantType` は grant_type を文字列で受けるため、拡張グラントにも使える。
実際 device grant は core を使わず、`validateDeviceCodeGrantAllowed` で同じ判定を独自に実装している。

```ts
export function validateDeviceCodeGrantAllowed(client: DeviceCodeGrantClient): void {
  if (!(client.grantTypes ?? []).includes(DEVICE_CODE_GRANT_TYPE)) {
    throw new DeviceAuthorizationError(
      'unauthorized_client',
      'The client is not authorized to use the device_code grant',
    );
  }
}
```

判定は等価だが、既定値の扱いが異なる。
core は `client.grantTypes ?? ['authorization_code']` と既定を補い、device 側は `?? []` とする。
device_code は既定に含まれないので結論は変わらないものの、**同じ規則が 2 箇所に別の形で書かれている**。

## 6. 現在の実装との差分

### 満たしていること

- 拡張グラントが動作すること自体は E2E と `conformance.test.ts` で確認されている
- 未知の grant_type に `unsupported_grant_type` を返す挙動は保たれている
- クライアント別 grant 認可（`unauthorized_client`）は、標準グラントでも拡張グラントでも実施されている

### 不足している可能性があること

- core を直接ライブラリとして使う利用者（CLAUDE.md が core の役割として挙げる「高度な組み込みユースケース」）は、拡張グラントを載せる手段を持たない。`validateTokenRequest` を呼ぶ前に自前で分岐するしかなく、その順序の正しさは利用者の責任になる
- 拡張グラントが増えるたびに、トークン発行の共通処理がテンプレート内で複製される。CIBA が入れば 3 例目になる
- `Cache-Control: no-store` のような、grant_type に依らず必ず要る処理が分岐ごとに書かれており、新しい分岐で抜ける余地がある

### 実装はあるが仕様上の確認が必要なこと

- `supportedGrantTypes` の意味。現状は「2 値のうちどれを有効にするか」であり、名前が示す「OP がサポートする grant_type の一覧」とは一致していない。Discovery の `grant_types_supported` を同じ配列から導出しようとすると齟齬が出る

### セキュリティ上、改善した方がよいこと

- 複製された処理のうち、抜けると影響が大きいのはトークンレスポンスのキャッシュ禁止（RFC 6749 §5.1）と、クライアント別 grant 認可である。前者は分岐ごとに手書きされており、後者は判定が二重化している。共通経路に寄せるほど、新しいグラントを足したときの取りこぼしが減る

### 相互運用性の観点で改善した方がよいこと

- Discovery の `grant_types_supported` が、実際に受理する grant_type の集合と別管理になっている。有効化した experimental 機能が広告に反映されるかは `study-material/done/discovery-metadata-experimental-features-core-expressibility.md` の範囲だが、拡張点を持てば「受理する集合」を単一の情報源にできる

### Basic OP として提供する上で確認すべきこと

- Basic OP が要求する grant_type は `authorization_code` のみであり、この構造は認定可否に影響しない。影響するのは拡張機能の追加コストである

## 7. 改善・追加を検討する理由

このリポジトリの差別化軸のうち Speed は「新しい仕様が出たとき最速で実装・追随する」ことを指す。
拡張グラントを 1 つ足すたびにテンプレートへ独立した分岐と重複コードが増える構造は、この軸に直接効く。
CIBA が 3 例目になる前に、共通化の形を決めておく価値がある。

利用者から見た価値は 2 つある。
core を直接使う利用者は、自作のグラント（社内向けの独自グラントなど）を core の検証パイプラインに載せられるようになる。
生成コードを読む利用者は、標準グラントと拡張グラントが同じ形で並ぶコードを読めるようになる。

導入しやすさの面では、core が既に「合成関数＋ステップ関数」の二層構成を持っている点が効く。
`validateGrantTypeSupported` が閉じた union を返すのが唯一の壁であり、ここを開くと `ValidatedTokenRequest` の判別共用体も開く必要が出る。
型の変更は破壊的変更になりうるので、後方互換の維持方法を先に決める必要がある。

実装しない場合に残る制約は、拡張グラントごとの重複と、core 単体利用での拡張不能である。
どちらも動作上の欠陥ではないため、experimental の追加ペースが落ち着くまで判断を保留する選択も成り立つ。

## 8. 実装方針の候補

最終的にどれを採るかは人間が判断する。

### 方針A: core にグラントハンドラの登録機構を置く

`TokenRequestContext` に、grant_type 文字列から検証関数へのマップを渡せるようにする。
`validateGrantTypeSupported` は、既知の 2 値かマップに存在する値のいずれかを受理する。
`ValidatedTokenRequest` に第 3 のメンバー（拡張グラント用の汎用形）を足す。

- 利点: core 単体利用でも拡張できる。`unsupported_grant_type` / `unauthorized_client` の切り分けが 1 箇所に集約される
- 欠点: `validateGrantTypeSupported` の戻り値型と `ValidatedTokenRequest` が変わる。既存の利用者コードに型エラーが出る可能性がある
- 確認が必要な点: 拡張グラントの検証結果を共通の形にできるか。実際の戻り値は揃っていない。`DeviceCodeGrantResult` は `subject` / `clientId` / `scope` / `authTime` / `grantId` をすべて必須で持つのに対し、`TokenExchangeGrant` は `authTime` を持たず `grantId` が optional で、代わりに `requestedAudience` と `expiresIn` を持つ。共通部分は `subject` / `clientId` / `scope` の 3 つにとどまり、ID Token 発行に要る `authTime` は grant ごとに扱いが分かれる

### 方針B: トークン発行の共通処理だけを関数として切り出す

grant 分岐の構造は現状のまま残し、「アクセストークン payload の組み立てから ID Token 発行、ストア保存、キャッシュヘッダ付与まで」をテンプレートが 1 つのヘルパーとして持つ。
device grant / token-exchange / 標準グラントがそれを呼ぶ。

- 利点: core の型を変えない。重複の大部分は消える
- 欠点: core 単体利用者は拡張できないまま。ヘルパーは生成コード側にあるので、利用者が改変すると全グラントに影響する

### 方針C: 迂回方式を明示的な契約として文書化する

構造は変えず、「拡張グラントは core の `validateTokenRequest` より前で分岐し、応答を返し切る」という規約を README とコメントに明記する。
新しいグラントを足すときのチェックリスト（クライアント認証の後に置く、キャッシュヘッダを付ける、クライアント別 grant 認可を行う）を残す。

- 利点: 変更なし。experimental の API 不安定性と整合する
- 欠点: 重複は残る。チェックリストの遵守は人手に依存する

### 方針D: 方針B を先に入れ、experimental の追加が落ち着いてから方針A を検討する

- 利点: 破壊的変更を先送りしつつ、重複だけ先に解消できる
- 欠点: 共通ヘルパーの形が方針A の共通形と食い違うと、二度手間になる

## 9. タスク案

- [ ] device grant / token-exchange の各分岐と標準グラントの分岐を突き合わせ、複製されている処理を一覧化する（署名鍵選択、issuer 切り替え、`aud` 合成、キャッシュヘッダ、refresh token 保存）
- [ ] `DeviceCodeGrantResult` と `TokenExchangeGrant` の差（`authTime` の有無、`grantId` の必須性、`requestedAudience` / `expiresIn`）を踏まえ、共通形を必須 3 項目＋任意項目にするか、grant ごとの型を保ったまま発行処理だけ共通化するかを決める
- [ ] 方針A / B / C / D のいずれで進めるかを決める
- [x] `supportedGrantTypes` の意味（絞り込み専用）を JSDoc に明記し、`validateClientGrantType` と `validateDeviceCodeGrantAllowed` の既定値の差を解消または明示する → `tasks/p3-supported-grant-types-contract-and-default-divergence.md` としてタスク化済み（方針決定を待たずに着手できる部分）
- [ ] 方針A を採る場合、`ValidatedTokenRequest` の型変更が破壊的変更にあたるかを `RELEASE.md` の方針に照らして判断し、changeset の bump 種別を決める
- [ ] CIBA の実装着手前にこの判断を終える（`tasks/experimental/ciba/`）
