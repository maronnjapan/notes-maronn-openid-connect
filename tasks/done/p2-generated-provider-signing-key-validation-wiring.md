# [P2] CLI 生成 OP に鍵強度・kid 整合の検証（`assertKeyStrength` / `assertKidStrategyConsistent`）を配線する

## ステータス

✅ 完了（2026-07-21）

## 背景

`packages/core` は署名鍵ガード `assertHasRs256Key` / `assertKeyStrength` / `assertKidStrategyConsistent` を export しているが、CLI 生成テンプレート・各 sample のどこも後者 2 つを呼び出していない。結果、CLI 生成 OP は 2048bit 未満の弱い RSA 鍵や `kid` が空/重複した壊れた複数鍵セットのまま黙って署名し得る。RS256 の**存在**は `buildProviderMetadata` 内で遅延的に検証されるが、**強度**と**kid 整合**はどこでも強制されない。core が用意した安全機構が配線漏れで死蔵している状態。

詳細な検討は `study-material/done/generated-provider-signing-key-validation-unwired.md` を参照。core 側のロジック自体は `study-material/done/signing-key-strength-and-parameter-validation.md` / `study-material/done/id-token-kid-presence-under-multiple-keys.md` で担保済み。本タスクは生成 OP への**配線**が対象。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（`createApp` の鍵ロード: L87-123 付近 / `applyOidc`: L2518-2531 付近）
- `packages/cli/src/frameworks/web-standard/templates.ts`（`createApp` の鍵ロード: L416-427 付近）
- （方針C採用時）`packages/core/src/signing-key.ts` にまとめ検証ファクトリを追加
- `samples/*/conformance.test.ts`（生成元 `packages/cli`）

## 仕様参照

- RFC 7518 §3.1 / §6.3（RSA 鍵強度）: https://www.rfc-editor.org/rfc/rfc7518#section-6.3
- RFC 7517 §4.5（`kid` による鍵選択）: https://www.rfc-editor.org/rfc/rfc7517#section-4.5
- RFC 9700 OAuth 2.0 Security BCP: https://www.rfc-editor.org/rfc/rfc9700
- 本リポジトリ契約: 生成コードの変更は `packages/cli` テンプレートで行い、`samples/*/conformance.test.ts` で担保する（CLAUDE.md）

## 現状の実装

- ガードの export: `packages/core/src/index.ts:156-162`。実装: `packages/core/src/signing-key.ts`。
- RS256 存在のみ遅延検証: `packages/core/src/discovery.ts:171`（`assertHasRs256Key`）。
- 鍵ロード時に強度・kid 整合を呼ぶ箇所は無し（`packages/cli` / `samples` 全体で `assertKeyStrength` / `assertKidStrategyConsistent` の呼び出しは 0 件）。

## 修正方針

まず PoC 用途で弱い鍵をあえて使うケースを壊さないか（既定 throw か警告か）を判断する。その上で:

- [ ] 方針を決定
  - [ ] 方針A: 鍵ロード直後に `assertHasRs256Key` + `assertKeyStrength` + `assertKidStrategyConsistent` を呼びフェイルファスト
  - [ ] 方針B: 既定は警告ログ、環境変数で厳格化（throw）を opt-in（PoC 配慮）
  - [ ] 方針C: core に「鍵セットを受け取り 3 ガードを実行するファクトリ」を追加し、テンプレートは 1 回呼ぶだけにして将来の配線漏れを防ぐ
- [ ] `assertKeyStrength` の既定しきい値（RSA 2048bit 等）が PoC 用途を過度に妨げないか確認
- [ ] 各テンプレート（hono `createApp`/`applyOidc`、web-standard `createApp`）に配線（方針Cなら core ファクトリを追加してから）

## テスト要件

- [ ] 2048bit 未満の RSA 鍵で生成 OP を起動しようとすると失敗する（方針A）／警告が出る（方針B）
- [ ] `kid` 空・重複の複数鍵セットで起動できない
- [ ] 正常な鍵セットでは従来どおり起動する（リグレッション無し）
- [ ] `samples/*/conformance.test.ts`（生成元 `packages/cli`）に上記契約テストを追加
- [ ] hono `createApp` / `applyOidc` の両入口で同じ検証が走ることを確認

## 完了条件

- `pnpm test`（core + 各 sample の生成物検証を含む）がパスすること
- 各 sample の `conformance.test.ts` がパスすること
