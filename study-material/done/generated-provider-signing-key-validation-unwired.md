# CLI 生成 OP が `assertKeyStrength` / `assertKidStrategyConsistent` を呼ばず、鍵強度・kid 整合の検証が未配線

## 1. このトピックで確認したいこと

`packages/core` は署名鍵ガードを 3 つ export している。

- `assertHasRs256Key`（RS256 鍵の存在: Basic OP 必須）
- `assertKeyStrength`（RSA 最小モジュラス長・許可曲線などの鍵強度）
- `assertKidStrategyConsistent`（複数鍵時の `kid` 空・重複を拒否）

しかし CLI 生成テンプレート・各 sample のどこも `assertKeyStrength` と `assertKidStrategyConsistent` を**呼び出していない**。結果として、CLI 生成 OP は 2048bit 未満の弱い RSA 鍵や、`kid` が空/重複した壊れた複数鍵セットのまま黙ってトークンに署名し得る。

本ファイルは「core が検証能力を持つか」（`study-material/done/signing-key-strength-and-parameter-validation.md` 等で扱い済み）ではなく、**そのガードが生成 OP に配線されていない**という差分に限定する。

## 2. 関連する仕様・基準

鍵強度・`kid` 選択の仕様説明は `study-material/done/signing-key-strength-and-parameter-validation.md`、`study-material/done/id-token-kid-presence-under-multiple-keys.md`、`study-material/jwks-endpoint-comprehensive.md` を参照し繰り返さない。ここでは配線ギャップに限定する。

- **RFC 7518 §3.1 / §6.3**: RSA 鍵は十分な強度（一般に 2048bit 以上）が必要。
- **RFC 7517 §4.5（`kid`）**: 複数鍵を JWKS で公開する場合、鍵選択のため `kid` が一意である必要がある。空・重複は署名検証時の鍵選択を壊す。
- **OAuth 2.0 Security BCP（RFC 9700）/ OIDC Core §10.1**: 署名鍵の管理・強度は OP のセキュリティ基盤。弱い鍵での署名は防止すべき。
- **本リポジトリの契約**: 生成 OP の挙動は `samples/*/conformance.test.ts` で担保し、生成コードの変更は `packages/cli` テンプレートで行う（CLAUDE.md）。したがって「ガードを呼ぶ」修正も CLI テンプレート側で行うべき。

## 3. 参照資料

- RFC 7518 §3.1 JWS Algorithms / §6.3 RSA — https://www.rfc-editor.org/rfc/rfc7518#section-6.3
- RFC 7517 §4.5 "kid" (Key ID) Parameter — https://www.rfc-editor.org/rfc/rfc7517#section-4.5
- RFC 9700 OAuth 2.0 Security BCP — https://www.rfc-editor.org/rfc/rfc9700
- 既存の関連記述（重複回避）: `study-material/done/signing-key-strength-and-parameter-validation.md`、`study-material/done/id-token-kid-presence-under-multiple-keys.md`

## 4. 現在の実装確認

- ガードの export: `packages/core/src/index.ts:156-162`（`assertHasRs256Key` / `assertKeyStrength` / `assertKidStrategyConsistent`）。実装は `packages/core/src/signing-key.ts`。
- RS256 の**存在**は `buildProviderMetadata` 内で `assertHasRs256Key` が呼ばれる（`packages/core/src/discovery.ts:171`）が、これは Discovery エンドポイントへのアクセス時に**遅延的**に走るだけ。鍵ロード時ではない。
- 鍵ロード箇所で強度・kid 整合を検証していない:
  - Hono `createApp`: `packages/cli/src/frameworks/hono/templates.ts:87-123` は `getSigningKey()` / `getRegisteredSigningKeys()` のみ。
  - Hono `applyOidc`: 同 `templates.ts:2518-2531` も同様。
  - web-standard（express/fastify/nextjs）`createApp`: `packages/cli/src/frameworks/web-standard/templates.ts:416-427` も同様。
  - sample も未呼び出し: `samples/hono/src/app.ts:88-112` 他。`packages/cli` / `samples` 全体で `assertKeyStrength` / `assertKidStrategyConsistent` の呼び出しは 0 件。

つまり、Basic OP 唯一の必須要件である RS256 の**存在**は（遅延的にせよ）担保されるが、**強度**と**kid 整合**はどこでも強制されない。

## 5. 現在の実装との差分

- **満たしていること**: RS256 鍵の存在は担保。core 単体テストで各ガードの正しさは検証済み。
- **不足している可能性があること**: 生成 OP が起動時／鍵ロード時に強度・kid 整合を検証しない。弱い鍵・壊れた kid セットで起動してしまう。
- **セキュリティ上の観点**: 2048bit 未満の RSA 鍵での署名は現実的な脅威。運用者が誤って弱い鍵を設定しても、フェイルファストせず署名を続ける。
- **相互運用性の観点**: `kid` が空/重複だと、RP が JWKS から鍵を選べず ID Token 検証に失敗し得る。起動時ガードがあれば運用者が即座に気付ける。
- **Basic OP として確認すべきこと**: 認定は RS256 の存在が主眼で、強度・kid 整合の起動時強制までは要求しない可能性が高い。ただし本リポジトリが「core にガードを用意しているのに生成 OP で使わない」状態は、提供物としての一貫性を欠く。

## 6. 改善・追加を検討する理由

- **なぜ検討するか**: core がわざわざ export しているガードが、利用者の入口である CLI 生成 OP でまったく使われていない。用意した安全機構が「配線漏れ」で無効化されている典型。
- **Basic OP 必須か拡張か**: 認定必須ではないハードニング。ただし OSS 実行利用者の安全性（弱い鍵でのフェイルファスト）に直結する。
- **導入しやすさ**: 生成テンプレートの鍵ロード直後に `assertKeyStrength(keys)` と（複数鍵時に）`assertKidStrategyConsistent(keys)` を呼ぶだけ。core 側の変更は不要。
- **既存実装との接続**: 既に `assertHasRs256Key` が discovery で使われているので、鍵ロード時に 3 ガードをまとめて呼ぶ形に寄せると意図が揃う。
- **実装しない場合のリスク**: 利用者が弱い鍵・壊れた kid セットで生成 OP を起動しても検知されず、署名が続く。core にガードがあることに気付かれず、安全機構が死蔵される。

## 7. 実装方針の候補（判断材料）

最終判断は人間が行う。生成コードの変更は必ず `packages/cli` テンプレート側で行う。

- 方針A（鍵ロード時にまとめて検証, 推奨）: `createApp` / `applyOidc` の鍵ロード直後に `assertHasRs256Key` + `assertKeyStrength` + `assertKidStrategyConsistent` を呼ぶヘルパを生成コードに入れる。起動時にフェイルファスト。
- 方針B（既定 policy を緩め、opt-in で厳格化）: 既定は警告ログのみ、環境変数で「厳格化（throw）」を有効化。利用者の PoC 用途で弱い鍵をあえて使うケースを壊さない配慮。ただし「安全は既定で ON」の原則からはやや後退。
- 方針C（core 側で鍵ロードを一元化）: core に「鍵セットを受け取り 3 ガードを実行して返す」ファクトリ（例: `assertSigningKeysValid`）を追加し、テンプレートはそれを 1 回呼ぶだけにする。将来ガードが増えても配線漏れを防げる。core への薄い追加が必要。
- いずれの方針でも、`assertKeyStrength` の既定しきい値（RSA 2048bit 等）が PoC 用途を過度に妨げないか要確認。

## 8. タスク案

- [ ] 方針（A / B / C）を決定。特に PoC 用途での弱い鍵利用を許すか（既定 throw か警告か）を判断
- [ ] `samples/*/conformance.test.ts`（生成元 `packages/cli`）に先行テスト:
  - [ ] 2048bit 未満の RSA 鍵で生成 OP を起動しようとすると失敗する（方針 A）／警告が出る（方針 B）
  - [ ] `kid` 空・重複の複数鍵セットで起動できない
  - [ ] 正常な鍵セットでは従来どおり起動する（リグレッション無し）
- [ ] `packages/cli` の各テンプレート（hono `createApp`/`applyOidc`、web-standard `createApp`）にガード呼び出しを追加（方針 C の場合は core にファクトリを追加）
- [ ] 生成し直した各 sample で `conformance.test.ts` がパスすることを確認
- [ ] 完了条件: `pnpm test`（core + 各 sample）がパス

## 関連トピック

- `study-material/done/signing-key-strength-and-parameter-validation.md` — core 側の強度検証ロジック。本ファイルはその生成 OP への配線ギャップ。
- `study-material/done/id-token-kid-presence-under-multiple-keys.md` — 複数鍵時の kid 必須。本ファイルは kid 整合ガードの起動時強制の配線。
- `study-material/done/hono-createapp-applyoidc-parity-and-conformance-path.md` — `createApp`/`applyOidc` の入口パリティ。鍵検証も両入口で揃える必要がある。
