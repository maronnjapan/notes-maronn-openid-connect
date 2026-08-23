# Request Object 内に `scope` があってもクエリ側 `scope` を必須にしており、コメントの §6.1 引用も不正確

## 1. このトピックで確認したいこと

Authorization Endpoint は、署名付き Request Object 内に `scope`（`openid` を含む）があっても、**トップレベルのクエリ `scope` が無いと `invalid_request`** で拒否する。OIDC Core §6.1 が OAuth リクエスト構文側に必須と定めるのは `response_type` と `client_id` のみで、`scope` は含まれない。該当コードのコメントは「§6.1: scope は OAuth 2.0 request syntax 側にも必ず含める」と述べているが、これは §6.1 の記述と一致しない。

本ファイルは、この **Request Object 使用時のクエリ `scope` 必須という厳格性の是非**、および**誤ったコメント**に限定する（Request Object のパース強度・replay・audience・request/request_uri 排他は別トピックで扱い済み）。

## 2. 関連する仕様・基準

Request Object の共通説明（by value のパース・検証）は `study-material/done/request-object-claim-validation-replay-and-audience.md` と `study-material/done/request-and-request-uri-mutual-exclusivity.md` を参照し繰り返さない。

- **OpenID Connect Core 1.0 §6.1（Passing a Request Object by Value）**:
  > "So that the request is a valid OAuth 2.0 Authorization Request, values for the response_type and client_id parameters MUST be included using the OAuth 2.0 request syntax, since they are REQUIRED by OAuth 2.0. The values for these parameters MUST match those in the Request Object, if present."

  クエリ構文側に必須なのは `response_type` と `client_id` の 2 つのみ。`scope` は「Request Object 内に載っていればそれで足りる」と読むのが素直。
- **OpenID Connect Core 1.0 §3.1.2.1**: `scope` は OpenID リクエストで必須（`openid` を含む）。ただし §6.1 の文脈では、その `scope` は Request Object 内で満たしてよい。
- 補足: 一部の実装は「クエリにも scope を要求」する厳格プロファイル（例: 特定の FAPI プロファイルや独自方針）を採るが、素の OIDC Core §6.1 はそこまで要求しない。本リポジトリのコメントは §6.1 を根拠として挙げているため、根拠と挙動の整合が問われる。

## 3. 参照資料

- OpenID Connect Core 1.0 §6.1 Passing a Request Object by Value — https://openid.net/specs/openid-connect-core-1_0.html#JWTRequests
- OpenID Connect Core 1.0 §3.1.2.1 Authentication Request — https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest
- 既存の関連記述（重複回避）: `study-material/done/request-object-claim-validation-replay-and-audience.md`、`study-material/done/request-and-request-uri-mutual-exclusivity.md`、`study-material/request-parameter-hygiene-and-override-contract.md`

## 4. 現在の実装確認

`packages/core/src/authorization-request.ts`:

```ts
// scope の検証
// OIDC Core 1.0 §6.1: scope は OAuth 2.0 request syntax 側にも必ず含める。   // L850: 不正確なコメント
// Request Object 内に scope がある場合はそちらを有効値として扱う（supersede）。
const queryScopeValue = params.scope;                                        // L852
if (!queryScopeValue) {                                                      // L853: クエリ scope 必須
  throw new AuthorizationError(
    AuthorizationErrorCode.InvalidRequest,
    'Missing required parameter: scope',
    redirectUri, state
  );
}
const scopeValue = effective.scope ?? queryScopeValue;                       // L862: RO 側を優先
```

- `effective.scope`（Request Object 由来）が存在しても、`params.scope`（クエリ）が無いと L853 で拒否される。
- L862 で最終的に RO 側 `scope` を優先しているにもかかわらず、その手前でクエリ `scope` の存在を必須化しているため、「RO に scope があるがクエリに無い」正当な §6.1 リクエストが弾かれる。
- コメント L850 は §6.1 を根拠にしているが、§6.1 は `scope` をクエリ必須とはしていない。

## 5. 現在の実装との差分

- **満たしていること**: `response_type` / `client_id` のクエリ必須・RO との一致は別途担保（§6.1 の本来の必須項目）。RO 側 `scope` を優先する supersede ロジックも存在する。
- **不足している可能性があること / 過剰な厳格性**: RO に `scope` があるのにクエリ `scope` を必須化するのは §6.1 より厳しい。素の OIDC Core RP が「クエリに scope を載せず RO に載せる」構成を弾く。
- **セキュリティ上の観点**: 厳格側なので危険ではない（むしろ安全側）。ただし「根拠として挙げた §6.1 が実挙動を支持しない」ため、Fidelity の主張として不正確。
- **相互運用性の観点**: RO に全パラメータを寄せる RP（JAR 前提の実装等）との相互運用を妨げ得る。
- **Basic OP として確認すべきこと**: Request Object（by value）は Basic OP 必須ではない。認定可否には直結しない。

## 6. 改善・追加を検討する理由

- **なぜ検討するか**: 少なくとも**コメントの根拠（§6.1）が挙動と不一致**である点は明確な是正対象。挙動そのもの（クエリ scope 必須）を緩めるかは方針判断だが、根拠の明示は Fidelity に直結する。
- **Basic OP 必須か拡張か**: 拡張（Request Object のフィデリティ）。
- **導入しやすさ**: 挙動を §6.1 準拠に緩めるなら、「RO に scope があればクエリ scope 不要」に分岐を変えるだけ。コメント修正だけなら実装変更ゼロ。
- **既存実装との接続**: `request-parameter-hygiene-and-override-contract.md` の supersede 契約と整合させる（RO 優先はそこで扱う方針）。
- **実装しない場合のリスク**: 誤った根拠コメントが残り、後続の実装者が §6.1 を誤解する。JAR 前提 RP との相互運用制約も残る。

## 7. 実装方針の候補（判断材料）

最終判断は人間が行う。

- 方針A（§6.1 準拠に緩和）: 「RO に `scope` があればクエリ `scope` は不要、両方無ければ `invalid_request`」に分岐を変更。`response_type`/`client_id` のクエリ必須は維持。最も §6.1 に忠実。
- 方針B（現状の厳格性を維持 + 根拠を正す）: クエリ scope 必須は独自の厳格プロファイルとして維持しつつ、コメントを「§6.1 は scope をクエリ必須としないが、本 OP は相互運用の明確性のためクエリ scope を要求する（独自方針）」と正確に書き換える。挙動は変えない。
- 方針C（設定で切替）: 既定は方針 A（§6.1 準拠）、厳格プロファイルを opt-in にする。柔軟だが設定面が増える。
- どの方針でも、まず「クエリ scope 必須が意図的な厳格化か、§6.1 の誤読か」を確認する。

## 8. タスク案（コメント是正は着手可能だが、挙動変更は方針判断を要するためタスク化は保留）

挙動を緩めるか（方針 A/C）現状維持で根拠だけ正すか（方針 B）が定まっていないため、実装タスクとしては保留する。判断材料のみ。

- [ ] 「クエリ scope 必須」が意図的な厳格プロファイルか §6.1 の誤読かを人間が確認
- [ ] 方針決定後、`authorization-request.test.ts` に「RO に scope・クエリに scope 無し」ケースのテストを先行追加（緩和なら成功、維持なら失敗を固定）
- [ ] コメント L850 を実挙動と一致する正確な記述に修正（どの方針でも実施）
- [ ] 挙動を変える場合は `samples/*/conformance.test.ts`（生成元 `packages/cli`）の Request Object 契約を更新

## 関連トピック

- `study-material/done/request-object-claim-validation-replay-and-audience.md` — RO のクレーム検証・replay・audience。
- `study-material/request-parameter-hygiene-and-override-contract.md` — クエリ/RO の supersede 契約。本ファイルの scope 優先はここに接続。
