# [P3] jwt-introspection-response の Accept 判定を RFC 9110 のコンテントネゴシエーションに整合させる

## ステータス

🟢 Low / 未着手

## 背景

`acceptsIntrospectionJwt`（`packages/experimental/src/jwt-introspection-response/accept.ts`）は Accept ヘッダをカンマで分割し、各要素の `;` より前を小文字比較するだけの実装で、次の 2 点が RFC 9110 の意味論とずれる。

1. **`q=0` の明示的拒否を「JWT 要求」として扱う**。`Accept: application/token-introspection+jwt;q=0, application/json` は「JWT は受け入れ不可」の宣言（RFC 9110 §12.4.2: q=0 は not acceptable）だが、現実装は JWT で応答する。現実装のコメントは「§4 に q 値の規定はなく、拒否したい RS はメディアタイプ自体を送らなければよい」とこの選択を記録済みであり、本タスクはその判断の再検討である
2. **quoted-string 内のカンマで誤分割する**。`Accept: text/html;p=",application/token-introspection+jwt,"` のようにパラメータの引用文字列にメディアタイプが含まれると、分割後の断片が完全一致して JWT 応答になる。影響は送信者自身の応答形式が変わるだけ（開示は増えない）だが、コメントに記録の無い未処理エッジである

どちらも「明示的に要求した呼び出し元だけが JWT を受け取る」という機能の契約を、HTTP の意味論のレベルで裏切るケースであり、2026-09-30 の実装レビュー（Phase 2 ルーティーン）で検出した。

## 対象ファイル

- `packages/experimental/src/jwt-introspection-response/accept.ts`（`acceptsIntrospectionJwt`）
- `packages/experimental/src/jwt-introspection-response/accept.test.ts`
- 実装解説 `implementation-guides/experimental/jwt-introspection-response.{ja,en}.md`（掲載コードの同期）

## 仕様参照

- RFC 9110 §12.4.2（Accept、qvalue の意味。q=0 は not acceptable）
- RFC 9110 §5.6.6（パラメータの quoted-string）
- RFC 9701 §4（Accept による JWT 応答の要求）

## 現状の実装

```ts
return acceptHeader.split(',').some((element) => {
  const mediaType = element.split(';')[0]?.trim().toLowerCase();
  return mediaType === TOKEN_INTROSPECTION_JWT_MEDIA_TYPE;
});
```

q 値を解釈せず、quoted-string を考慮しない。

## 修正方針

- [ ] 要素分割を quoted-string を跨がない形にする（引用中のカンマ・セミコロンを区切りにしない）
- [ ] 当該メディアタイプの要素に `q=0`（`0.0` 等の表記ゆらぎを含む）が付いていれば JWT 要求と見なさない
- [ ] q 値による選好順位付け（JSON と JWT の優先比較）までは踏み込まない。「明示された・かつ拒否されていない」の判定に留め、現行の「ワイルドカードは JWT と解釈しない」方針は維持する
- [ ] コメントの設計判断の記述を新しい挙動へ更新する

## テスト要件

- [ ] `application/token-introspection+jwt;q=0` → JSON 応答（JWT 要求と見なさない）
- [ ] `application/token-introspection+jwt;q=0.000` / `q=1` / `q=0.5` の境界
- [ ] `text/html;p=",application/token-introspection+jwt,"` → JSON 応答
- [ ] 既存ケース（単独指定・複数指定・大文字小文字・ワイルドカード非解釈）の回帰

## 完了条件

- experimental の単体テストが通り、生成 conformance テストに回帰がない
- 実装解説（ja / en）の掲載コードと説明が更新されている
