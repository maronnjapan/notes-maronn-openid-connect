# 受信 JWS 検証（id_token_hint / Request Object）で `crit` ヘッダ未拒否・`alg` とヘッダ非束縛

## 1. このトピックで確認したいこと

OP が**受信した JWS を検証する** 2 経路（`id_token_hint` の署名検証、Request Object の署名検証）で、共通する 2 つの JOSE ヘッダ強度の穴を確認する。

1. **`crit`（Critical）ヘッダ未処理**: どちらの経路も JOSE ヘッダから `alg` / `kid` しか読まず、`crit` を検査しない。理解できない critical 拡張を列挙した `crit` を持つ JWS でも、署名が通れば受理される。RFC 7515 §4.1.11 は「理解できない `crit` 値があれば JWS を拒否しなければならない（MUST）」と定める。
2. **`alg` がヘッダから検証鍵に束縛されていない**: 検証アルゴリズムを JOSE ヘッダの `alg` からではなく JWK の鍵材料（`kty`/`crv`）から導出しており、ヘッダ `alg` と実際の検証アルゴリズムが一致することを強制していない。

この 2 点は「OP 自身の署名鍵ポリシー」や「`alg:none` 防御」（`study-material/jws-algorithm-policy-and-alg-none-defense.md` で扱い済み）とは別の、**受信 JWS 検証経路のヘッダ強度**という差分。id_token_hint も Request Object も Basic OP 必須ではないため、優先度は低いが、JWS 検証の共通ハードニングとして 1 トピックにまとめる。

## 2. 関連する仕様・基準

`alg:none` 拒否・署名アルゴリズムポリシーの共通説明は `study-material/jws-algorithm-policy-and-alg-none-defense.md` と `study-material/jwt-bcp-rfc8725.md` を参照し繰り返さない。

- **RFC 7515 §4.1.11（`crit`）**:
  > "If any of the listed extension Header Parameters are not understood and supported by the recipient, then the JWS MUST be rejected."

  `crit` を無視して受理するのは MUST 違反。少なくとも「`crit` が存在し、かつ理解できる登録済みパラメータのみでない場合は拒否」が必要。
- **RFC 8725 §3.11（Use Explicit Typing / Header 検証）**、**RFC 8725 §3.1（Perform Algorithm Verification）**: 検証側は「信頼できる情報源から得たアルゴリズムで」検証すべきで、鍵から盲目的に推定した alg で検証すべきでない。ヘッダ `alg` と検証鍵・許可アルゴリズムの一致を確認する。
- 補足: 現状 `alg` は `supportedSigningAlgs` に対しては検査される（許可リスト）。欠けているのは「ヘッダ `alg` と実際に鍵から導出される検証アルゴリズムの一致」の束縛。

## 3. 参照資料

- RFC 7515 §4.1.11 "crit" (Critical) Header Parameter — https://www.rfc-editor.org/rfc/rfc7515#section-4.1.11
- RFC 8725 §3.1 / §3.11 JSON Web Token Best Current Practices — https://www.rfc-editor.org/rfc/rfc8725
- RFC 7517 §4.2 "use" / §4.3 "key_ops"（検証鍵は sig 用途であるべき） — https://www.rfc-editor.org/rfc/rfc7517#section-4.2
- 既存の関連記述（重複回避）: `study-material/jws-algorithm-policy-and-alg-none-defense.md`、`study-material/jwt-bcp-rfc8725.md`、`study-material/done/request-object-jws-parsing-hardening-parity.md`

## 4. 現在の実装確認

- `id_token_hint` 検証: `packages/core/src/id-token.ts`（`validateIdTokenHint`）
  - JOSE ヘッダから `alg` / `kid` のみ参照（L269-282 付近）。`crit` を読む箇所は無い。
  - 候補鍵の絞り込みは `kid`（または `alg`）一致のみで、`use === 'sig'` / `key_ops` によるフィルタが無い（L286-288 付近）。`enc` 用途の鍵が渡された JWKS に含まれると検証に選ばれ得る（現実の露出は限定的: `exportPublicJwk` は常に `use:'sig'` を付与するが、公開関数は任意の `JwkSet` を受け付ける）。
- Request Object 検証: `packages/core/src/request-object.ts`
  - JOSE ヘッダから `alg` / `kid` のみ参照（L103-137 付近）。`crit` を読む箇所は無い（リポジトリ全体 grep でも `crit` の処理は 0 件）。
  - 検証アルゴリズムは `extractAlgorithmParamsFromJwk(jwk)`（`crypto-utils.ts:352-380`）が `kty`/`crv` から導出（L140-158 付近）。ヘッダ `alg` は許可リスト照合には使うが、鍵から導出した検証アルゴリズムとの一致は束縛していない。

いずれも `.test.ts` に `crit` ケース・alg/key 束縛ケースは無い。

## 5. 現在の実装との差分

- **満たしていること**: `alg` の許可リスト検証、`alg:none` 拒否、署名検証自体（署名が合わなければ失敗）。
- **不足している可能性があること**:
  - `crit` ヘッダの拒否（RFC 7515 §4.1.11 の MUST）。両経路とも未実装。
  - 検証鍵の `use`/`key_ops` フィルタ（id_token_hint 経路）。
  - ヘッダ `alg` と鍵から導出される検証アルゴリズムの一致束縛（Request Object 経路）。
- **セキュリティ上の観点**: いずれも直ちに悪用可能とは言い難い（署名検証が最終防波堤）。ただし `crit` 無視は仕様 MUST 違反で、拡張パラメータの意味を無視して受理する潜在リスク。use-confusion / alg-key mismatch は多層防御としては塞いでおくのが望ましい。
- **相互運用性の観点**: `crit` を正しく拒否することで、拡張前提の JWS を「理解したふりで受理」する事故を防げる。
- **Basic OP として確認すべきこと**: id_token_hint も Request Object（by value）も Basic OP 必須ではない。認定可否には直結しない。

## 6. 改善・追加を検討する理由

- **なぜ検討するか**: `crit` 拒否は RFC 7515 の MUST。受信 JWS 検証は 2 経路に分散しているため、共通ハードニングとして一括で扱うと漏れが減る。
- **Basic OP 必須か拡張か**: 拡張（optional 機能の JWS 検証強度）。ただし「JWS を検証する以上 `crit` の MUST は守る」という Fidelity 観点で価値がある。
- **導入しやすさ**: 両経路のヘッダ解析直後に「`crit` があり、理解できる登録済み名のみでなければ拒否」を足す小さな共通ヘルパで対応可能。use フィルタ・alg 束縛も局所修正。
- **既存実装との接続**: `study-material/done/request-object-jws-parsing-hardening-parity.md` が「2 経路のパース強度を揃える」方針を既に持つため、`crit` もその「両経路パリティ」の一項目として自然に接続できる。
- **実装しない場合のリスク**: `crit` MUST 違反が残る。将来 JWE / JAR 拡張を入れた際に、critical 拡張の未処理が顕在化しやすい。

## 7. 実装方針の候補（判断材料）

最終判断は人間が行う。

- 方針A（`crit` 拒否の共通ヘルパを両経路に適用, 推奨）: 「理解できる登録済みヘッダ名の集合」を定義し、`crit` に載る名がその外にあれば拒否する共通関数を追加。id_token_hint と Request Object の両ヘッダ解析後に呼ぶ。現状 OP が独自 critical 拡張を実装していないなら「`crit` が存在したら一律拒否」でも実害は小さい。
- 方針B（`crit` 拒否 + use フィルタ + alg 束縛をまとめて）: 上記に加え、検証鍵候補を `use === 'sig'`（または `key_ops` に verify を含む）に限定し、Request Object 経路でヘッダ `alg` と鍵導出アルゴリズムの一致を検証。網羅的だが変更範囲が広い。
- 方針C（現状維持 + 文書化）: 「OP は critical 拡張を扱わない前提であり `crit` を持つ JWS は想定外」とし、判断を `study-material/done/request-object-jws-parsing-hardening-parity.md` に追記。ただし MUST 違反の解消にはならない。

## 8. タスク案（タスク化は保留 — ポリシー判断が必要）

対象がオプショナル機能であり、`crit` 拒否の粒度（一律拒否か登録名許可か）や use/alg 束縛までやるかの方針が定まっていないためタスク化しない。

- [ ] `crit` の扱い（一律拒否 / 登録名許可）を決定
- [ ] use フィルタ・alg 束縛まで踏み込むか（方針 A / B）を判断
- [ ] `id-token.test.ts` / `request-object.test.ts` に `crit` 付き JWS 拒否・use/alg 束縛のテストを先行追加
- [ ] 両経路に共通ヘルパを配線
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test` がパス

## 関連トピック

- `study-material/jws-algorithm-policy-and-alg-none-defense.md` — `alg` ポリシー・`alg:none` 防御。本ファイルは `crit` / alg-key 束縛という別軸。
- `study-material/done/request-object-jws-parsing-hardening-parity.md` — Request Object と id_token_hint のパース強度パリティ。本ファイルの `crit` はその一項目として接続できる。
