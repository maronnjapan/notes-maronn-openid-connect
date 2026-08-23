# PAR エンドポイントが Request Object（`request` パラメータ）を無条件で拒否する

## ステータス

🟠 High（相互運用性 / 拡張性）/ 未着手

## 1. タイトル

Pushed Authorization Requests（RFC 9126）の実装が、RFC 9126 §3 で明示的に許可されている `request` パラメータ（JAR / RFC 9101 の Request Object）を `invalid_request` で拒否している点の確認と、解消方針の整理。

## 2. このトピックで確認したいこと

`packages/experimental/src/par` は PAR を実装済みで、CLI の `--enable par` で生成 OP に載る。
一方 `packages/core` は署名付き Request Object（`request` パラメータ）を認可エンドポイントで受理する実装を持っている。
つまり本リポジトリは PAR と JAR の両方を個別には実装しているのに、**両者を組み合わせたリクエストだけが通らない**。

このファイルで確認したいのは次の三点である。

- RFC 9126 が PAR ボディへの `request` 同梱をどこまで許容しているか（MAY か、それとも実装裁量か）
- 現在の拒否が仕様上どの程度の逸脱にあたるか（Basic OP 認定には影響しないが、FAPI 2.0 系プロファイルの前提を満たせるか）
- 解消する場合、core を変更せずに experimental 側だけで閉じられるか

### 既存ファイルとの関係（重複回避）

| 論点 | 扱っているファイル |
|---|---|
| JAR（RFC 9101）そのものの導入可否、`request_uri` 外部参照の非対応方針 | `study-material/ext-jar-request-object-rfc9101.md`、`study-material/request-object-rejection-and-discovery-honesty.md` |
| PAR の導入判断、Basic OP との関係、Discovery メタデータ | `study-material/ext-pushed-authorization-requests-rfc9126.md`、`study-material/extension-pushed-authorization-requests-par.md` |
| Request Object の JWS 検証強度・クレーム検証・リプレイ | `study-material/done/request-object-claim-validation-replay-and-audience.md`、`study-material/done/request-object-jws-parsing-hardening-parity.md` |
| クライアント登録の `request_object_signing_alg` 強制 | `study-material/client-request-object-signing-alg-enforcement.md` |
| FAPI 2.0 プロファイル全体 | `study-material/ext-fapi-2-0-security-profile.md` |
| study-material のステータス陳腐化（PAR を「未実装」と書いた記述の是正） | `tasks/p3-study-material-duplicate-topic-consolidation.md` |

上記の PAR / JAR ファイルはいずれも **PAR 実装前**に書かれており、「PAR の `request_uri` と JAR の `request_uri` をどう判別するか」までは触れているが、**PAR ボディの `request` パラメータ**については扱っていない。
本ファイル固有の差分は「実装済みの PAR エンドポイントが、実装済みの Request Object 経路へ接続されていない」という現在の状態に限る。

## 3. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` §3.3 を参照する。ここでは本トピックに直接効く条文だけを引く。

### 3.1 RFC 9126 §3（Request Object）

RFC 9126 §3 は、PAR ボディに Request Object を積むことを明示的に許可している。

> Clients MAY use the `request` parameter as defined in JAR [RFC9101] to push a Request Object JWT to the authorization server.

続けて、その場合はクライアント認証に必要なパラメータ（`client_assertion`、`client_id` など）を除き、認可リクエストパラメータは JWT のクレームとして表現される、と定めている。
`request` の同梱は MAY であり、認可サーバに実装義務は生じない。
ただし「クライアントが送ってくる可能性のある正当なリクエスト」であることは仕様が認めている。

### 3.2 RFC 9126 §2.1 / §4（パラメータの扱い）

§2.1 は、`client_id` が認可リクエストの必須パラメータである以上、pushed request でも同様に必須だと定める。
トークンエンドポイントのクライアント認証用パラメータは認証のためだけに存在し、認可リクエストそのものには属さない。

§4 は、pushed request から生じた認可リクエストを、認可サーバが他の認可リクエストと同様に検証しなければならない（MUST）と定める。
push 時点で実施済みの検証は、pushed request であると確認できる限り省略してよい（MAY）。

### 3.3 FAPI 2.0 Security Profile との関係

FAPI 2.0 Security Profile は認可リクエストの送信経路として PAR を要求する。
署名付きリクエスト（JAR）を要求するのは FAPI 2.0 Message Signing 側であり、Security Profile 単体では JAR は必須ではない。
両者を併用するプロファイルを検証しようとする利用者にとっては、PAR と JAR を同時に使えるかどうかが分岐点になる。

## 4. 参照資料

- RFC 9126 OAuth 2.0 Pushed Authorization Requests §2.1 / §3 / §4 / §5 — https://www.rfc-editor.org/rfc/rfc9126
  - §3 の "Clients MAY use the `request` parameter as defined in JAR [RFC9101] to push a Request Object JWT to the authorization server." を根拠にしている
- RFC 9101 The OAuth 2.0 Authorization Framework: JWT-Secured Authorization Request (JAR) — https://www.rfc-editor.org/rfc/rfc9101
- OpenID Connect Core 1.0 §6.1（Request Object by value） — https://openid.net/specs/openid-connect-core-1_0.html#RequestObject
- FAPI 2.0 Security Profile — https://openid.net/specs/fapi-security-profile-2_0.html

## 5. 現在の実装確認

### 5.1 PAR エンドポイント側

`packages/experimental/src/par/par-request.ts` の `rejectForbiddenParParams` が、`request` を含む pushed request を無条件で `invalid_request` にする。

```ts
export function rejectForbiddenParParams(params: Record<string, string>): void {
  if (params['request_uri'] !== undefined) {
    throw new ParError(
      'invalid_request',
      'request_uri MUST NOT be included in a pushed authorization request',
    );
  }
  if (params['request'] !== undefined) {
    throw new ParError(
      'invalid_request',
      'The request parameter (Request Object) is not supported by this pushed authorization request endpoint',
    );
  }
}
```

`request_uri` の拒否は RFC 9126 §2.1 の MUST NOT に対応しており、正しい。
`request` の拒否は仕様の要求ではなく、実装が置いた非目標である（JSDoc に「PAR と Request Object (JAR) の併用は本機能の非目標」と明記されている）。

この関数は合成関数 `handlePushedAuthorizationRequest` の最初のステップであり、生成 OP のルートもこの順序で呼ぶ。
したがって `request` を積んだ pushed request は、クライアント認証にも到達せずに 400 で落ちる。

### 5.2 認可エンドポイント側（core）

`packages/core/src/authorization-request.ts` の `resolveRequestObjectParams` が `request` を JWS として検証し、`mergeRequestObjectParams` でクエリパラメータに重ねる。
署名検証はクライアント登録の `jwks` に対して行われ、受理する `alg` は既定 `["RS256"]`。
`request_uri` は `rejectUnsupportedRequestParams` が `request_uri_not_supported` で拒否する。

### 5.3 両者の接続点

`packages/experimental/src/par/resolve-request-uri.ts` の `resolvePushedRequestUri` は、URN 形式の `request_uri` を store から consume し、保存済みパラメータを返す。
生成 OP はその戻り値でリクエストパラメータを丸ごと差し替えてから、core の検証パイプラインへ流す。

```ts
const pushedParams = await resolvePushedRequestUri({ params: rawParams, store: parStore });
if (pushedParams !== null) {
  ...
  params = pushedParams;
}
```

保存レコードから `request_uri` は除去されるが、`request` は除去対象になっていない。
つまり **仮に PAR エンドポイントが `request` を受理して保存していれば、認可エンドポイント側は追加変更なしで core の Request Object 経路に流せる**。
拒否しているのは入口の 1 関数だけである。

## 6. 現在の実装との差分

### 満たしていること

- RFC 9126 §2.1 の `request_uri` MUST NOT を実装している
- RFC 9126 §4 の「pushed request も通常の認可リクエストと同様に検証する」を、保存パラメータを core の検証へ流すことで満たしている
- PAR の `request_uri`（URN 前置詞で判別）と OIDC Core §6.2 の外部参照 `request_uri` を取り違えない分離ができている

### 不足している可能性があること

- RFC 9126 §3 が MAY として認めるクライアント挙動（`request` を積んだ pushed request）を受理できない。仕様違反ではないが、仕様が想定する正当なクライアントを一律に弾いている
- Discovery が `request_parameter_supported: true` を広告したまま PAR エンドポイントだけが `request` を拒否するため、**同じ OP の中でパラメータ受理可否が入口ごとに食い違う**。クライアントは Discovery からこの差を読み取れない
- PAR と JAR を組み合わせるプロファイル（FAPI 2.0 Message Signing 相当）の検証ができない

### 実装はあるが仕様上の確認が必要なこと

- PAR ボディに `request` があるとき、ボディの他のパラメータと Request Object クレームのどちらを優先するか。RFC 9126 §3 はクライアント認証用を除くパラメータが JWT クレームとして表現されると述べるが、両方送られた場合の優先順位を明示していない。OIDC Core §6.1 の「Request Object の値が supersede する」を援用するのが自然だが、`response_type` / `client_id` の一致検証をどの時点で行うかは設計判断になる
- 保存するレコードに Request Object の生 JWT を残すか、展開後のパラメータを残すか。前者は認可エンドポイントで再検証でき、後者は保存量が小さい

### セキュリティ上、改善した方がよいこと

- 現状の拒否そのものは安全側であり、受理する側に倒すと Request Object の検証面が PAR エンドポイントにも増える。PAR エンドポイントは未認証ではなくクライアント認証済みなので、`request-object-jws-parsing-hardening-parity` で扱った入力サイズ・パース強度の要求は認可エンドポイントより緩められる。それでも同じ検証関数を通すのが安全である

### 相互運用性の観点で改善した方がよいこと

- 主要な IdP（Keycloak、Authlete、Ping 等）は PAR ボディの `request` を受理する。クライアントライブラリによっては PAR 利用時に自動で Request Object を組み立てるものがあり、そうしたクライアントは現状の生成 OP に接続できない

### Basic OP として提供する上で確認すべきこと

- PAR も JAR も Basic OP 認定の対象外であり、この差分は認定可否に影響しない

## 7. 改善・追加を検討する理由

このリポジトリの差別化軸は Speed / Fidelity / Portability であり、Fidelity は「仕様に忠実であること」を指す。
RFC 9126 §3 が明示的に認めるクライアント挙動を拒否している状態は、この軸から見て説明が必要な欠けになる。

利用者の側から見ると、価値は「PoC で FAPI 2.0 相当の構成を試せるか」に集約される。
PAR 単体は既に試せるが、署名付きリクエストと組み合わせた構成は試せない。
本リポジトリが想定する利用者（本番導入を見据える開発者）は、要件として JAR を課される場面に遭遇しうる。

導入しやすさの面では、必要な部品がすべて揃っている点が大きい。
Request Object の検証は core にあり、保存パラメータを認可エンドポイントへ流す配管も既にある。
入口の 1 関数を変え、保存時に Request Object をどう展開するかを決めるだけで閉じる可能性が高い。

実装しない場合に残る制約は、上記の相互運用性の欠けと、FAPI 系プロファイルの検証不能である。
どちらも Basic OP の範囲外なので、優先度を下げる判断も成り立つ。

## 8. 実装方針の候補

最終的にどれを採るかは人間が判断する。ここでは判断材料だけを並べる。

### 方針A: PAR エンドポイントで Request Object を展開してから保存する

`rejectForbiddenParParams` から `request` の拒否を外し、`validatePushedAuthorizationParams` が呼ぶ `validateAuthorizationRequest` にそのまま任せる。
core は既に `request` を展開・検証するので、追加の検証コードは要らない。
保存するのは展開後のパラメータとし、`request` 自体は保存対象から外す（`CLIENT_AUTHENTICATION_PARAMS` と同じ扱いにする）。

- 利点: 変更量が最小。認可エンドポイント側は無変更。検証が 1 箇所に集約される
- 欠点: 認可エンドポイントでは Request Object の署名を再検証しない。RFC 9126 §4 の「push 時点の検証は省略してよい」に沿うが、保存層が改竄された場合の防御は store の信頼に依存する
- 確認が必要な点: `validateAuthorizationRequest` の戻り値ではなく生パラメータを保存しているため、Request Object 由来の値を保存レコードへ反映する処理を追加する必要がある

### 方針B: Request Object の生 JWT を保存し、認可エンドポイントで再検証する

PAR エンドポイントでは検証だけ行い、保存レコードには `request` をそのまま残す。
認可エンドポイントは復元したパラメータを core へ流し、core が改めて署名検証する。

- 利点: 署名検証が認可エンドポイントでも走るため、store の完全性への依存が減る
- 欠点: 同じ JWS を 2 回検証する。Request Object のリプレイ検知（`done/request-object-claim-validation-replay-and-audience.md`）と組み合わせると、2 回目が「再利用」と判定されないよう調整が要る
- 確認が必要な点: リプレイ検知の粒度を PAR 経路で変える必要があるか

### 方針C: 現状維持のうえ、Discovery と文書で非対応を明示する

`request` の非対応を仕様上の欠けとして受け入れ、生成 OP の README とコメントに明記する。

- 利点: 変更なし。検証面が増えない
- 欠点: Discovery の `request_parameter_supported` は認可エンドポイントの能力を表す値であり、PAR エンドポイントの差を表現するメタデータは RFC 9126 に無い。文書だけで補うことになる

## 9. タスク案

- [ ] RFC 9126 §3 と RFC 9101 §5 を読み合わせ、PAR ボディに `request` と個別パラメータが両方来た場合の優先順位を決める（OIDC Core §6.1 の supersede 規則を援用するかを含む）
- [ ] 方針A / B / C のいずれで進めるかを決める
- [ ] 方針A または B を採る場合、`rejectForbiddenParParams` から `request` の拒否を外し、`par-request.test.ts` に受理ケースを追加する
- [ ] 保存レコードに `request` を残すか展開後パラメータを残すかを決め、`createPushedAuthorizationRecord` の除外リストを更新する
- [ ] `tests/e2e` に「PAR で Request Object を push し、認可エンドポイントで展開される」E2E スペックを追加する
- [ ] `packages/cli` のテンプレートと各 sample の `conformance.test.ts` を更新し、PAR + Request Object の受理・拒否挙動を契約として固定する
- [ ] `docs/implementation-guides/experimental/` の PAR 解説（日本語版・英語版の両方）に、Request Object の扱いを追記する
- [ ] `pnpm review:experimental par` でパケットを再生成し、同じコミットに含める
