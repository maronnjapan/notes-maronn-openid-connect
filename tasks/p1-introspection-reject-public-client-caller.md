# [P1] introspection エンドポイントで public client の client_id 単独提示を拒否する

## ステータス

🟠 High / 未着手

## 背景

生成 OP の introspection エンドポイントは token エンドポイントと同じクライアント認証パイプラインを使う。
このパイプラインは `token_endpoint_auth_method: 'none'` で登録されたクライアントを「資格情報の不提示」だけ確認して通すため、public client の `client_id`（公開情報）を body に置くだけで introspection が成立する。

- RFC 7662 §2.1 は token scanning 防止のため呼び出し元の認可を要求する
- RFC 9701 §5 は未認証の introspection リクエストを 400 で拒否することを MUST とする
- `--enable jwt-introspection-response` 時はこの開示が AS 署名付き JWT になり、caller 制限（audience 制限）の同一性判定の根拠が自称の client_id になる

ルート自身のコメント「Confidential client only — public clients are out of scope for this template」とも矛盾する。
生成 conformance アプリの testClients には method `'none'` の `c-public` が常に登録されており、既定生成物で成立する。

詳細は `study-material/done/introspection-public-client-unauthenticated-caller.md` を参照。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（introspection ルートテンプレート。web-standard 変換で 4 フレームワークへ展開される）
- 必要なら `packages/core/src/introspection.ts` または `client-auth.ts`（confidential 必須の検証ステップを core に置く場合）
- `packages/cli/src/__tests__/`（generator テスト）
- 生成 conformance テストテンプレート（public client_id のみのケース追加）
- `tasks/experimental/done/jwt-introspection-response/specification.md` と `study-material/done/introspection-caller-authorization-and-disclosure.md` の前提記述の訂正

## 仕様参照

- RFC 7662 §2.1（呼び出し元の認可を要求）
- RFC 9701 §5 Note（未認証呼び出しの拒否 MUST・400）
- RFC 7009 §2.1（対比: revocation は public client を正当に許す。今回の変更対象にしない）

## 現状の実装

- `extractClientCredentials` → body に client_id のみなら `method: 'none'`
- `validateClientAuthMethod` → 登録方式 `'none'` なら不提示のみ確認して return
- `verifyClientSecret` → 登録方式 `'none'` はスキップ
- introspection ルートは通過後の `client_id` を認証済み呼び出し元として扱う（JSON 経路・JWT 経路とも）

## 修正方針

- [ ] introspection ルートの認証パイプライン直後に「登録方式が `'none'` のクライアントを `invalid_client`（401 + WWW-Authenticate）で拒否する」ステップを追加する
- [ ] JSON 経路（RFC 7662）と JWT 経路（RFC 9701）の両方より前に効く位置に置く
- [ ] revocation ルートには適用しない（RFC 7009 §2.1 で public client は正当）
- [ ] ルートコメントの「Confidential client only」を実挙動として担保する
- [ ] specification.md と introspection-caller-authorization-and-disclosure.md の「クライアント認証必須で MUST を満たす」前提を訂正する
- [ ] jwt-introspection-response の実装解説（ja / en）の掲載コードと説明を同じ変更内で更新する

## テスト要件

- [ ] `should reject an introspection request that presents only a public client_id`（401 / invalid_client。4 フレームワーク）
- [ ] `should reject a public client introspection request even when it asks for the JWT response`（`--enable jwt-introspection-response` 時）
- [ ] `should keep answering an authenticated confidential client as before`（回帰）
- [ ] 生成 conformance テストへ public client_id のみのケースを追加する

## 完了条件

```bash
pnpm --filter @maronn-openid-connect/cli test
pnpm --filter @maronn-openid-connect/experimental test
pnpm typecheck
pnpm test:conformance
pnpm run test:e2e
```

- 上記がすべて成功する
- 生成 OP へ `client_id=c-public&token=...` を POST すると 401 / invalid_client が返る（Accept が JWT メディアタイプでも同じ）
