# [P3] CIBA binding_message の制御文字検証を C1・双方向制御文字へ広げる

## ステータス

🟢 Low / 未着手

## 背景

`binding_message` の制御文字判定は `code < 0x20 || code === 0x7f`（C0 と DEL のみ）で、C1 制御文字（U+0080–U+009F）と双方向制御文字（U+202A–U+202E、U+2066–U+2069）を受理する。
HTML エスケープはこれらを無害化しないため、RTL オーバーライドで承認画面の binding_message 表示を視覚的に偽装でき、CIBA Core §7.1 の「CD と AD の両画面での目視照合」という目的を弱める。
また長さ判定が UTF-16 コードユニット数のため、サロゲートペアを 2 文字と数える（拒否方向のずれで軽微）。

詳細は `study-material/done/ciba-binding-message-control-character-coverage.md` を参照。

## 対象ファイル

- `packages/experimental/src/ciba/backchannel-authentication-request.ts`（制御文字判定と長さ判定）
- `packages/experimental/src/ciba/backchannel-authentication-request.test.ts`
- 実装解説 `implementation-guides/experimental/ciba.{ja,en}.md`（掲載コードの同期）

## 仕様参照

- CIBA Core 1.0 §7.1（binding_message の表示照合目的）・§14
- Unicode UAX #9（明示的双方向制御文字）

## 現状の実装

```typescript
const code = char.codePointAt(0) ?? 0;
return code < 0x20 || code === 0x7f;
```

## 修正方針

- [ ] 判定を `code < 0x20 || (code >= 0x7f && code <= 0x9f)` へ拡張する（C0 + DEL + C1）
- [ ] 双方向制御文字 U+202A–U+202E と U+2066–U+2069 を拒否リストへ加える（U+200E / U+200F を含めるかは実装時に判断し、判断をコメントに残す）
- [ ] 長さを `[...bindingMessage].length`（コードポイント数）で数える
- [ ] エラーは既存どおり `invalid_binding_message`
- [ ] experimental は自動 changeset（patch 固定）なので changeset は書かない
- [ ] 実装解説（ja / en）の掲載コードと説明を同じ変更内で更新する

## テスト要件

- [ ] `should reject a binding message containing a C1 control character`
- [ ] `should reject a binding message containing an RTL override character`
- [ ] `should count astral characters as one character for the length limit`
- [ ] 既存の C0 / DEL / 長さ上限テストの回帰確認

## 完了条件

```bash
pnpm --filter @maronn-openid-connect/experimental test
pnpm typecheck
pnpm test:conformance
```
