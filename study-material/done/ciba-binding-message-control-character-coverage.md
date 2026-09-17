# CIBA binding_message の制御文字検証が C0/DEL のみで C1・双方向制御文字を素通しする問題

## 1. このトピックで確認したいこと

CIBA の `binding_message` 検証が拒否する制御文字の範囲が C0（U+0000–U+001F）と DEL（U+007F）に限られており、C1 制御文字（U+0080–U+009F）と双方向制御文字（U+202A–U+202E、U+2066–U+2069）を受理する。表示照合というこのパラメータの目的に照らして十分かを確認する。

## 2. 関連する仕様・基準

- CIBA Core 1.0 §7.1: binding_message は CD（consumption device）と AD（authentication device）の両画面に表示し、End-User が目視で照合する。
- CIBA Core 1.0 §14（セキュリティ考慮）。
- 実装意図: コードの JSDoc と `tasks/experimental/done/ciba/specification.md` はどちらも「制御文字を拒否する」と記す。

## 3. 参照資料

- `packages/experimental/src/ciba/backchannel-authentication-request.ts`（制御文字判定 `code < 0x20 || code === 0x7f`）
- Unicode Bidirectional Algorithm（UAX #9）の明示的方向制御文字

## 4. 現在の実装確認

```typescript
const code = char.codePointAt(0) ?? 0;
return code < 0x20 || code === 0x7f;
```

HTML エスケープ（XSS 対策の二層目）は施されているが、C1 と双方向制御文字はエスケープでは無害化されない。付随して、長さ判定が `bindingMessage.length`（UTF-16 コードユニット数）でサロゲートペアを 2 と数え、文書の「1〜100 文字」より厳しい側にずれる。

## 5. 現在の実装との差分

- 🟠 RTL オーバーライド文字を含む binding_message が受理され、承認画面の表示を視覚的に偽装できる。§7.1 の「両画面での照合」という目的を弱める。
- 🟢 C0 / DEL の拒否、HTML エスケープ、長さ上限は実装済み。ずれは拒否方向なので相互運用上は軽微。

## 6. 改善・追加を検討する理由

binding_message の存在意義は「攻撃者が用意したセッションと利用者が見ているセッションの取り違えを、目視照合で防ぐ」ことにある。表示を偽装できる文字の受理はこの意義を直接損なう。判定関数 1 箇所の拡張で済み、既存テストの形式にも沿う。

## 7. 実装方針の候補

- 制御文字判定を `code < 0x20 || (code >= 0x7f && code <= 0x9f)` へ拡張し、双方向制御文字（U+202A–U+202E、U+2066–U+2069、必要なら U+200E/U+200F も検討）を拒否リストに加える。
- 長さは `[...str].length`（コードポイント数）で数える。
- 実装解説（ciba.ja.md / ciba.en.md）の掲載コードを同じ変更内で更新する。

## 8. タスク案

- [ ] 制御文字判定の拡張と、C1 / bidi / サロゲートペアのテスト追加

→ `tasks/p3-ciba-binding-message-control-characters.md` としてタスク化済み。
