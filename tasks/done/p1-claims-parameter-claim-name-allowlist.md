# [P1] `claims` パラメータのクレーム名にアロウリストを導入し、任意プロパティ読み出しを塞ぐ

## ステータス

✅ 実装済み（2026-10-29）

実装メモ：

- `packages/core/src/userinfo.ts` に `DEFAULT_REQUESTABLE_CLAIMS`（`sub` ＋ `SCOPE_CLAIMS_MAP` の全クレーム名）を導入し、`applyRequestedClaims` にアロウリスト引数（既定は同定数）と `hasOwnProperty` 検査を追加した。`getRequestedClaimNames` の実態と食い違う `as (keyof UserClaims)[]` キャストは除去した。
- タスク記載時点と異なり、ID Token 側にも `applyRequestedIdTokenClaims`（`packages/core/src/token-response.ts`）があり同じ任意キー読み出しを持っていたため、同じアロウリストを適用した。
- タスクが挙げた `handleUserInfoRequest` / `UserInfoRequestContext` と「samples の conformance.test.ts」は現行構成に存在しない（ステップ構成への移行と生成物検査テストの廃止）。apps / samples は core の既定値を通じて保護されるため、生成コード側の変更は不要だった。
- resolver 契約は `UserClaimsResolver.findUserClaims` の JSDoc と `study-material/resolver-and-store-contract.md` に追記した。

---

以下は着手前のタスク内容。

## 背景

UserInfo の `applyRequestedClaims` は、`claims.userinfo` の **キー名をそのまま `userClaims` のプロパティ名として読み出す**。
読み出してよいクレーム名の集合が定義されておらず、`hasOwnProperty` 検査も無い。

一方 scope 由来の経路（`filterClaimsByScope`）は `SCOPE_CLAIMS_MAP` に載っているクレーム名だけをコピーする
アロウリスト方式である。**同じ `UserClaims` に対して scope 経路はアロウリスト、`claims` 経路は任意キー読み出し**という非対称がある。

`UserClaimsResolver.findUserClaims()` は利用者が実装する。DB の行オブジェクトや内部ユーザーモデルを
そのまま返す実装は PoC で最も自然な書き方であり、その場合
`claims={"userinfo":{"password_hash":null}}` のようなリクエスト 1 本で、
**scope とは無関係にその内部フィールドが UserInfo レスポンスから返る**。

`UserClaims` は閉じた interface で、`getRequestedClaimNames` は `as (keyof UserClaims)[]` とキャストしているため
**型で守られているように読めるが、いずれも実行時の防御ではない**（TypeScript の構造的部分型では
変数経由の余剰プロパティは検査されない）。この「見た目の安全性」が本タスクの主眼。

影響範囲は UserInfo レスポンスに限定される（ID Token 側は `filterClaimsByScope` しか通らない）。
→ 実装時点では `applyRequestedIdTokenClaims` が導入済みで、ID Token 側にも同じ経路があった（上記実装メモ参照）。

検討詳細は `study-material/done/claims-parameter-claim-name-allowlist.md` を参照。

> 関連（重複しない）:
> - 要求クレームを返してよいと**誰が判断したか**（同意境界）: `study-material/claims-parameter-consent-authorization-boundary.md`
> - 非標準クレームを**運べるようにする**拡張性: `study-material/userinfo-custom-claims-and-scope-claim-mapping-extensibility.md`
> - `value` / `values` / `essential` の判定規則: `study-material/done/claims-parameter-value-values-essential.md`
>
> 本タスクは「**読み出してよいキーの集合を定義する**」ことだけを対象とする。

## 対象ファイル

- `packages/core/src/userinfo.ts`（`getRequestedClaimNames` / `applyRequestedClaims` / `SCOPE_CLAIMS_MAP`）
- `packages/core/src/userinfo.test.ts`
- `study-material/resolver-and-store-contract.md`（resolver 契約の追記）
- （実装時に追加）`packages/core/src/token-response.ts`（`applyRequestedIdTokenClaims`）と `packages/core/src/token-response.test.ts`

## 仕様参照

- **OIDC Core 1.0 §5.5.1 Individual Claims Requests**: 要求されたクレームを返せない場合でも
  OP は **エラーを返してはならない（MUST NOT return an error）**。`essential` についても
  「best effort で提供する SHOULD」であり、**返さないことは常に仕様適合**。
  → アロウリストで絞ることは仕様違反にならない。
- **OIDC Core 1.0 §5.5**: `claims` は「RP が要求できる」ことを定めるだけで、
  「OP が無条件に返してよい」とは定めていない。返す範囲は OP が決める。
- **OIDC Core 1.0 §5.1 / §5.1.2**: クレーム名は **OP が定義し公開する語彙**。
  Additional Claims は「OP と RP の合意のもとで」使うものと規定されている。
- **OIDC Discovery 1.0 §3**: `claims_supported` は OP が返しうるクレーム名のリスト。
  語彙の宣言場所として仕様が用意している項目（現在は実行時判断に使われていない）。

## 修正方針（着手前の計画）

- [x] `applyRequestedClaims` に **`hasOwnProperty` 検査**を追加し、プロトタイプチェーン由来のプロパティを読まない
- [x] `applyRequestedClaims` に **アロウリスト引数**を追加する（既定は `SCOPE_CLAIMS_MAP` の全クレーム ＋ `sub`）
- [x] 引数は optional にし、将来 Discovery の `claims_supported` を注入できる形にしておく
- [x] 既定値を使う限り**既存の挙動は変わらない**ことを保証する
- [x] `UserClaimsResolver.findUserClaims` の JSDoc に契約を追記する
- [x] `study-material/resolver-and-store-contract.md` に同契約を追記する
- [x] `getRequestedClaimNames` の戻り値型を `string[]` に直し、実態と食い違うキャストを除去する
- [x] （計画外・同趣旨）`applyRequestedIdTokenClaims` にも同じアロウリストを適用する
- `handleUserInfoRequest` / `UserInfoRequestContext` の拡張、`packages/cli` テンプレート修正、samples の conformance.test.ts 追加は、現行構成に該当範囲が存在しないため実施しない

## テスト要件（実施結果）

`packages/core/src/userinfo.test.ts` に追加済み：

- [x] `should return a standard claim requested via the claims parameter`
- [x] `should not return a non-standard property present on the resolved user claims`
- [x] `should not return a prototype chain property when requested as a claim`
- [x] `should not alter the response prototype when __proto__ is requested as a claim`
- [x] `should return only claims within an explicitly supplied allowlist`
- [x] 既存の `claims` 関連テストが引数追加後も無変更で通る（後方互換の確認）
- [x] `should not return an error when a requested claim is not allowed`

`packages/core/src/token-response.test.ts` に追加済み：

- [x] `should not add a non-standard property present on the claims of the End-User`
- [x] `should add only claims within an explicitly supplied allowlist`

## 完了条件（実施結果）

- [x] `pnpm --filter @maronn-openid-connect/core test`（1336 テストパス）
- [x] `pnpm test:conformance`（パス）
- [x] `pnpm typecheck`（パス）
- [x] `packages/core/src/userinfo.ts` から `as (keyof UserClaims)[]` のキャストが除去されている
- [x] `study-material/resolver-and-store-contract.md` と `UserClaimsResolver` の JSDoc に
  「`findUserClaims` の戻り値は外部開示されうる面である」旨の契約が記載されている
