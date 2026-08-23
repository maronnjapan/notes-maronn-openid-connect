# Token Endpoint クライアント認証: 未知 client_id の早期 return が client 列挙のタイミングオラクルになる

## 1. このトピックで確認したいこと

`authenticateClient` は、`findClient(clientId)` が `null`（未知クライアント）のとき即座に `throw` し、定数時間比較 `timingSafeEqual` に到達しない。一方、既知クライアントでシークレットが不一致の場合は `timingSafeEqual` を通ってから失敗する。この**コードパスの分岐**により、「未知の client_id」と「既知の client_id + シークレット誤り」で応答レイテンシが異なり、client_id 列挙のタイミングオラクルになり得る。

本ファイルは「シークレット比較自体が定数時間か」（`study-material/security-client-secret-handling.md` / タスク済み `p0-client-secret-timing-safe-comparison`）ではなく、**比較の前段で client の存在有無が漏れる**という差分に限定する。

## 2. 関連する仕様・基準

クライアント認証・定数時間比較の共通説明は `study-material/security-client-secret-handling.md` を参照し繰り返さない。

- **OAuth 2.1 §7.4.1 / RFC 6749 §10.10（Credentials-Guessing / Timing Attacks）**: クレデンシャル検証はタイミング攻撃に耐えるべき。定数時間比較が推奨される。存在有無で早期 return するとタイミング差が生じる。
- **一般的なユーザ名列挙対策の類推**: 「不明ユーザ」でも「既知ユーザ + パスワード誤り」でも同一の処理時間・同一のエラーを返す（ダミー比較を行う）のがベストプラクティス。client_id は準公開のことも多いが、confidential client の存在自体を秘匿したい構成では列挙耐性が意味を持つ。

## 3. 参照資料

- OAuth 2.1 draft §7.4.1 — https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- RFC 6749 §10.10 Credentials-Guessing Attacks — https://www.rfc-editor.org/rfc/rfc6749#section-10.10
- 既存の関連記述（重複回避）: `study-material/security-client-secret-handling.md`、タスク `tasks/done/p0-client-secret-timing-safe-comparison.md`

## 4. 現在の実装確認

`packages/core/src/client-auth.ts`（`authenticateClient`）:

```ts
const client = await clientResolver.findClient(clientId);
if (!client) {                                    // L151: 未知クライアントは即 throw
  throw new TokenError(
    TokenErrorCode.InvalidClient,
    'Client authentication failed',
  );
}
// ... registeredMethod 判定 ...
const secretMatches = await timingSafeEqual(client.clientSecret ?? '', clientSecret);  // L195: 既知のときだけ到達
if (!secretMatches) {
  throw new TokenError(TokenErrorCode.InvalidClient, 'Client authentication failed');
}
```

- 未知 client_id: `findClient` が `null` → L151 で即 throw。`timingSafeEqual` を通らない。
- 既知 client_id + シークレット誤り: `registeredMethod` 判定・`timingSafeEqual`（L195）を通ってから失敗。
- テスト（`client-auth.test.ts:166` 付近）はエラーコードのみを固定しており、未知クライアント時のダミー比較やタイミングは未検証。

`findClient` 自体の実装（resolver）にも依存する。ストアが「存在するときだけ遅い」ような差を持つと、オラクルはさらに顕著になる。

## 5. 現在の実装との差分

- **満たしていること**: 既知クライアントのシークレット比較は定数時間（`timingSafeEqual`）。エラーコードは両ケースとも `invalid_client` で統一されており、**エラー内容**からは区別できない。
- **不足している可能性があること**: 未知クライアント時にダミーの定数時間比較を行わないため、**処理時間**で存在有無が漏れ得る。
- **セキュリティ上の観点**: client_id が秘匿対象でない構成では実害は小さいが、confidential client の存在秘匿を要件とする構成ではタイミングオラクルが列挙面になる。
- **相互運用性の観点**: 影響なし（挙動・エラーは仕様準拠）。純粋なハードニング。
- **Basic OP として確認すべきこと**: 認定要件ではない。列挙耐性は運用要件に依存する。

## 6. 改善・追加を検討する理由

- **なぜ検討するか**: 既にシークレット比較を定数時間化しているのに、その手前の存在チェックでタイミングが漏れるのは対策の穴。ダミー比較を足すだけで閉じられる。
- **Basic OP 必須か拡張か**: 認定必須ではないオプショナルなハードニング。
- **導入しやすさ**: 未知クライアント時に「固定ダミー値との `timingSafeEqual`」を実行してから同じ `invalid_client` を throw する定型パターンで対応可能。ただし `findClient`（resolver / ストア）側のタイミング差までは core で吸収しきれない点に注意。
- **既存実装との接続**: `timingSafeEqual` は既にあるので、未知パスでも 1 回呼ぶだけ。
- **実装しない場合のリスク**: client 存在有無のタイミングオラクルが残る。列挙耐性を要件とする利用者が自前で塞ぐ必要がある。

## 7. 実装方針の候補（判断材料）

最終判断は人間が行う。

- 方針A（未知パスでダミー定数時間比較, 推奨）: `findClient` が `null` のとき、固定ダミー文字列に対して `timingSafeEqual` を 1 回実行してから `invalid_client` を throw する。既知・未知でシークレット比較の実行回数を揃える。
- 方針B（現状維持 + 文書化）: 「client_id は準公開情報であり列挙耐性は非目標」と割り切り、`study-material/security-client-secret-handling.md` に判断を明記。実装コスト 0。PoC 用途では妥当な割り切りとの主張も成り立つ。
- 方針C（resolver 契約に定時間ルックアップを要求）: ストア実装に「存在有無でタイミングを変えない」ことを契約化。core だけでは担保できないため、`study-material/resolver-and-store-contract.md` への追記と組み合わせる。効果は高いが利用者への要求が増える。
- 注意: core でダミー比較を足しても、`findClient` の I/O タイミング差（DB ルックアップの有無など）が支配的な場合はオラクルが残る。方針 A は「アプリ層の分岐差」を消すもので、完全な定時間化ではないことを明記すべき。

## 8. タスク案（タスク化は保留 — 目標設定の判断が必要）

列挙耐性を目標とするか（方針 A/C）割り切るか（方針 B）は運用要件次第で、方針が定まっていないためタスク化しない。判断のための項目のみ挙げる。

- [ ] 「confidential client の存在秘匿」を提供物の目標に含めるかを人間が判断
- [ ] 含める場合、方針 A（core のダミー比較）と方針 C（resolver 契約）のどちらまで踏み込むか決定
- [ ] `client-auth.test.ts` に「未知クライアントでも `timingSafeEqual` が 1 回呼ばれる／同一エラーになる」テストを追加してから実装
- [ ] resolver 側タイミング差の残存を `study-material/resolver-and-store-contract.md` に明記

## 関連トピック

- `study-material/security-client-secret-handling.md` — シークレットの取り扱い・定数時間比較。本ファイルは比較の前段の存在オラクルという別軸。
- `study-material/resolver-and-store-contract.md` — resolver 契約。定時間ルックアップの要否をここに接続できる。
