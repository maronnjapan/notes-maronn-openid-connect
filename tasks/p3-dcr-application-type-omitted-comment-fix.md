# [P3] DCR の application_type 省略時検査を説明する JSDoc を実挙動に合わせて訂正する

## ステータス

🟢 Low / 未着手

## 背景

`validateRedirectUrisForApplicationType` の JSDoc 最終段落が「application_type を省略した登録には、core の規則（validateRegisteredRedirectUris）だけが掛かる」と説明している。
しかし PR #160（コミット 936hd05 ではなく 936df05）で `validateClientMetadata` は省略時を `web` として扱い、同関数で種別制約を検査するようになった。
これは OIDC Dynamic Client Registration 1.0 §2 の MUST（省略時の既定 web、redirect_uris の種別制約の確認）に合わせた変更で、コードが正しい。
コメントを信じて「省略時は種別検査を飛ばす」よう修正されると仕様違反へ戻るため、コメント側を直す。

詳細は `study-material/done/dcr-application-type-omitted-comment-drift.md` を参照。

## 対象ファイル

- `packages/experimental/src/dynamic-client-registration/metadata-values.ts`（`validateRedirectUrisForApplicationType` の JSDoc 最終段落）
- 実装解説 `implementation-guides/experimental/dynamic-client-registration.{ja,en}.md`（掲載コードの同期。notes リポジトリ側のコミット）

## 仕様参照

- OIDC Dynamic Client Registration 1.0 §2（application_type の既定値と redirect_uris の種別制約）

## 現状の実装

コードの挙動は正しい。JSDoc の最終段落のみが変更前の挙動を説明している。

## 修正方針

- [ ] JSDoc 最終段落を「application_type を省略した登録は web として検査する（OIDC Dynamic Client Registration 1.0 §2 の省略時既定）」の趣旨へ書き換える
- [ ] 実装解説（ja / en）の掲載コードと説明を同じ変更内で同期する
- [ ] コードの挙動は変更しない

## テスト要件

- [ ] 既存テストがすべて通ること（挙動変更が無いことの確認）

## 完了条件

```bash
pnpm --filter @maronn-openid-connect/experimental test
```

- 「core の規則だけが掛かる」という説明が実装・解説のどこにも残っていない
