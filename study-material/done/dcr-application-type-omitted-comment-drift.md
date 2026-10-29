# DCR の application_type 省略時検査を説明する JSDoc が実装と食い違う問題（コードは正しく、コメントが古い）

## 1. このトピックで確認したいこと

Dynamic Client Registration の `validateRedirectUrisForApplicationType`（`packages/experimental/src/dynamic-client-registration/metadata-values.ts`）の JSDoc が、「application_type を省略した登録には、core の規則（validateRegisteredRedirectUris）だけが掛かる」と説明している。
しかし呼び出し側の `validateClientMetadata`（同パッケージ `registration-request.ts`）は、省略時を `web` として扱い、同関数で種別制約を検査するよう既に変更されている。
コードが仕様どおりで、コメントだけが変更前の挙動を説明したまま残っていることを確認する。

## 2. 関連する仕様・基準

- OIDC Dynamic Client Registration 1.0 §2: `application_type` は省略時の既定が `web`。AS は、登録するすべての redirect_uris がその種別の制約（web かつ implicit grant なら https かつ localhost 以外、native ならカスタムスキームかループバックの http）に従うことを確かめなければならない（MUST）。

## 3. 参照資料

- 実装の変更: コミット 936df05「fix(dcr): register the OIDC Registration 1.0 defaults and verify redirect_uris for an omitted application_type」（PR #160）。`validateClientMetadata` が省略時に `web` を適用し、`validateRedirectUrisForApplicationType` を必ず呼ぶようになった
- 古い記述: `packages/experimental/src/dynamic-client-registration/metadata-values.ts` の `validateRedirectUrisForApplicationType` の JSDoc 最終段落
- 転載先: 実装解説 `implementation-guides/experimental/dynamic-client-registration.{ja,en}.md`（掲載コード全文一致の規約により、同じ古い段落をそのまま載せている）

## 4. 現在の実装確認

`registration-request.ts` の `validateClientMetadata` は、`metadata['application_type']` が undefined のとき `'web'` を `validateApplicationType` に渡し、その結果で `validateRedirectUrisForApplicationType` を呼ぶ。
したがって省略した登録にも web の種別制約（implicit grant を登録した場合の https・非 localhost 制約）が掛かり、OIDC Dynamic Client Registration 1.0 §2 の MUST に合致する。

## 5. 現在の実装との差分

- 🟢 コードの挙動は仕様に合致している。
- 🟠 `metadata-values.ts` の JSDoc 最終段落だけが「省略時は core の規則だけが掛かる」という変更前の挙動を説明しており、同ファイルを読む改修者を誤導する。コメントを信じて「省略時は種別検査を飛ばす」よう修正されると、§2 の MUST 違反に戻る。
- 🟠 実装解説（ja / en）はこの JSDoc を全文転載しているため、同じ誤記を公開している。

## 6. 改善・追加を検討する理由

挙動の変更を伴わない文言修正だけで、仕様違反へ巻き戻す誤修正のリスクを消せる。
実装解説は掲載コードの全文一致を規約とするため、JSDoc の修正と同じ変更内で解説の同期も必要になる。

## 7. 実装方針の候補

- JSDoc 最終段落を実挙動に合わせて書き換える（例: 「application_type を省略した登録は web として検査する（OIDC Dynamic Client Registration 1.0 §2 の既定値）」）。コードの挙動変更は不要。
- 実装解説（ja / en）の掲載コードを同じ変更内で同期する。

## 8. タスク案

- [ ] JSDoc の文言修正と実装解説の同期

→ `tasks/p3-dcr-application-type-omitted-comment-fix.md` としてタスク化済み。
