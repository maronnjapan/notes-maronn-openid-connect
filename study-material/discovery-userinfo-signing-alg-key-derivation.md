# Discovery: `userinfo_signing_alg_values_supported` を実鍵から導出せず手動リストのまま広告している

## 1. このトピックで確認したいこと

`buildProviderMetadata` は `id_token_signing_alg_values_supported` を**実際の署名鍵集合から導出**し、OP が生成できないアルゴリズムを広告できないようにしている。一方 `userinfo_signing_alg_values_supported` は呼び出し側が渡す手動の文字列リストを**無検証でそのまま広告**する。UserInfo も OP が署名する対象であるにもかかわらず、ID Token に適用している「広告は実鍵能力から導く」フットガン防止が適用されていない。結果、OP が実際には署名できない UserInfo 署名アルゴリズムを広告し得て、署名付き UserInfo のクライアント側検証を壊す可能性がある。

本ファイルは、この **ID Token と UserInfo の広告導出の非対称**という差分に限定する（UserInfo 署名応答の生成自体は別トピックで扱い済み）。

## 2. 関連する仕様・基準

署名付き UserInfo の生成・配線は `study-material/done/userinfo-signed-response.md`（および `tasks/done/p0-userinfo-signed-response-wiring.md`）を参照し繰り返さない。Discovery メタデータの共通説明は `study-material/discovery-optional-metadata-fields.md` を参照。

- **OpenID Connect Discovery 1.0 §3**:
  > "userinfo_signing_alg_values_supported OPTIONAL. JSON array containing a list of the JWS signing algorithms (alg values) [JWA] supported by the UserInfo Endpoint to encode the Claims in a JWT."

  「UserInfo Endpoint が実際にサポートする」alg を広告するフィールド。OP が生成できない alg を載せるのは広告と実挙動の乖離。
- **OpenID Connect Core 1.0 §5.3.2（Successful UserInfo Response）**: UserInfo を署名付き JWT で返す場合、`userinfo_signed_response_alg` に従う。OP はその alg で実際に署名できなければならない。
- **参考: `request_object_signing_alg_values_supported` との違い**: こちらは**クライアントが署名し OP が検証する** alg なので手動リストで妥当。UserInfo は**OP が署名する**ため、ID Token 同様に実鍵から導出するのが整合的。この非対称が本ファイルの論点。

## 3. 参照資料

- OpenID Connect Discovery 1.0 §3 — https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata
- OpenID Connect Core 1.0 §5.3.2 UserInfo Response — https://openid.net/specs/openid-connect-core-1_0.html#UserInfoResponse
- 既存の関連記述（重複回避）: `study-material/done/userinfo-signed-response.md`、`study-material/discovery-optional-metadata-fields.md`

## 4. 現在の実装確認

`packages/core/src/discovery.ts`:

```ts
// ID Token: 実鍵から導出（L175-183 付近）
const idTokenAlgs: string[] = [];
const seenAlgs = new Set<string>();
for (const key of config.idTokenSigningKeys) {
  const alg = getJwaAlgorithm(key);
  if (!seenAlgs.has(alg)) { seenAlgs.add(alg); idTokenAlgs.push(alg); }
}
// ...
id_token_signing_alg_values_supported: idTokenAlgs,          // L192

// UserInfo: 手動リストを無検証パススルー（L209-215 付近）
if (config.userinfoSigningAlgValuesSupported &&
    config.userinfoSigningAlgValuesSupported.length > 0) {
  metadata.userinfo_signing_alg_values_supported =
    config.userinfoSigningAlgValuesSupported;
}
```

- ID Token: 鍵集合から alg を導出し、鍵に無い alg は広告不可。導出理由はコメント（L22-30 付近）に明記。
- UserInfo: 呼び出し側の文字列配列をそのまま広告。UserInfo 署名鍵の実能力との突き合わせが無い。

なお UserInfo 署名鍵は ID Token とは別プロバイダになり得る（`idTokenSigningKeyProvider` / `userinfoSigningKeyProvider` の分離）。そのため UserInfo alg は UserInfo 用鍵集合から導出するのが正しい。

## 5. 現在の実装との差分

- **満たしていること**: ID Token alg の実鍵導出は堅牢。UserInfo alg の受け渡し自体は動作する。
- **不足している可能性があること**: UserInfo alg を UserInfo 署名鍵から導出（または最低限クロスチェック）していない。実際に署名できない alg を広告し得る。
- **セキュリティ上の観点**: 直接の脆弱性ではないが、広告と実挙動の乖離は誤設定の温床。
- **相互運用性の観点**: RP が Discovery を信頼して `userinfo_signed_response_alg` を選ぶと、OP が署名できず UserInfo 応答生成に失敗し得る。導出/検証で乖離を防げる。
- **Basic OP として確認すべきこと**: 署名付き UserInfo は Basic OP 必須ではない。認定可否には直結しない。

## 6. 改善・追加を検討する理由

- **なぜ検討するか**: ID Token に適用済みの「広告は実鍵能力から」の思想を、同じく OP が署名する UserInfo に適用していない非対称。意図的な割り切りか見落としかが不明。
- **Basic OP 必須か拡張か**: 拡張（署名付き UserInfo のフィデリティ）。
- **導入しやすさ**: UserInfo 署名鍵プロバイダが config にあるなら、ID Token と同じ導出ロジックを再利用できる。鍵プロバイダが非同期取得で discovery 構築時に鍵が手元に無い場合は、導出できず「クロスチェック（渡された alg が導出可能な範囲か検証）」に留める判断もある。
- **既存実装との接続**: `getJwaAlgorithm` による導出関数を UserInfo 鍵集合にも適用するだけ。
- **実装しない場合のリスク**: 広告と実挙動の乖離が残り、署名付き UserInfo を使う RP との相互運用で誤設定が顕在化する。

## 7. 実装方針の候補（判断材料）

最終判断は人間が行う。これは「意図的な割り切りか是正すべき非対称か」の判断を含む。

- 方針A（UserInfo 署名鍵から導出）: `config` に UserInfo 署名鍵集合を渡し、ID Token と同じ導出ロジックで `userinfo_signing_alg_values_supported` を生成。discovery 構築時に鍵が同期取得できることが前提。
- 方針B（手動リストを実鍵でクロスチェック）: 手動リストは受けつつ、UserInfo 署名鍵から導出可能な alg 集合の部分集合であることを検証し、外れた alg があれば拒否/警告。鍵が構築時に取得できない構成でも部分的に守れる。
- 方針C（現状維持 + 意図の明記）: 「UserInfo alg は運用者責任で手動指定」と割り切り、`study-material/discovery-optional-metadata-fields.md` に判断を明記。ID Token との非対称の理由（鍵プロバイダが非同期で構築時に取得できない等）を記録。

## 8. タスク案（タスク化は保留 — 非対称の是非の判断が必要）

「意図的な割り切りか是正か」が定まっていないためタスク化しない。

- [ ] UserInfo 署名鍵が discovery 構築時に同期取得できるか（鍵プロバイダの取得タイミング）を確認
- [ ] 上記を踏まえ方針 A / B / C を判断
- [ ] 是正する場合、`discovery.test.ts` に「UserInfo 鍵に無い alg を広告しない/拒否する」テストを先行追加
- [ ] 生成 OP の Discovery 出力が変わるなら `samples/*/conformance.test.ts`（生成元 `packages/cli`）を更新

## 関連トピック

- `study-material/done/userinfo-signed-response.md` — 署名付き UserInfo の生成。本ファイルはその Discovery 広告の実鍵整合という別軸。
- `study-material/discovery-optional-metadata-fields.md` — Discovery のオプショナルフィールド一般。
