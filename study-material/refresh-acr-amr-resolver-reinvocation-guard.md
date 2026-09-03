# refresh 時に acr / amr resolver が再実行されうる core API のガード不足

## ステータス

🟡 Medium / 未着手（実装方針の決定待ち。タスク化はまだしない）

## 1. このトピックで確認したいこと

「refresh_token grant では acr / amr resolver を再実行しない」という不変条件が、
core の API 自体で守られているかを確認する。

`resolveAcrAmr` はこの不変条件を「直接指定値（保存済み acr / amr）があれば resolver を呼ばない」
という形で実装している。
初回認証が acr / amr を生まなかった場合、保存値は無いので、refresh 時の呼び出しは
このガードをすり抜けて resolver に到達する。
resolver が呼ばれれば、認証イベントが発生していない refresh に対して
新しい認証コンテキストが主張されることになる。

## 2. 関連する仕様・基準

- OIDC Core 1.0 §2
  - `acr` は「the Authentication Context Class that the authentication performed satisfied」、
    `amr` は「authentication methods used in the authentication」。
    どちらも実際に行われた認証についての主張である。
- OIDC Core 1.0 §12.2（Successful Refresh Response）
  - 再発行 ID Token の `auth_time` などは元の認証を表す値を保持し、
    「otherwise, the same rules apply as apply when issuing an ID Token at the time of
    the original authentication」とする。
    refresh の時点で認証は行われていないため、そこで新たに算出した acr / amr は
    元の認証を表さない。

## 3. 参照資料

- OpenID Connect Core 1.0 §2 / §12.1 / §12.2
- `tasks/done/p0-refresh-acr-amr-persistence.md`
  （保存済み acr / amr を refresh で引き継ぐ実装。「refresh では resolver を呼ばない」を
  要件として明記しているが、resolver が undefined を返した未保存ケースには触れていない）
- `study-material/refresh-grant-claims-context-not-preserved.md`
  （「現状は directAcr 優先のため実害なし」と評価しているが、その前提は
  保存値が存在するケースに限られる）

## 4. 現在の実装確認

`packages/core/src/token-response.ts` の `resolveAcrAmr`:

```typescript
if (acr !== undefined || amr !== undefined) {
  return { acr, amr };
}
if (!acrResolver) {
  return { acr: undefined, amr: undefined };
}
// ...（claims.id_token.acr.values の seed 処理）...
const result = await acrResolver({ userId: subject, clientId, requestedAcrValues: effectiveRequestedAcrValues });
```

保存値が両方 undefined のとき、resolver が渡っていれば呼ばれる。
`RefreshTokenInfo.acr` / `amr` は optional であり、
「resolver が判断を辞退して undefined を返す」ケースは
`token-response-steps.test.ts` がサポート対象として固定している。
つまり未保存状態は仕様内の通常状態である。

CLI 生成コードは呼び出し側でガードしている（`packages/cli/src/frameworks/hono/templates.ts` の
token route が `grantType === 'authorization_code'` のときだけ resolver を渡す）。
そのため生成された Provider では発生しない。
発生するのは、core の `generateTokenResponse` / `resolveAcrAmr` を直接使い、
refresh 経路でも resolver を渡し続ける組み込み構成である。

## 5. 現在の実装との差分

- 満たしていること
  - 保存済み acr / amr がある refresh では resolver を呼ばない（テストで固定済み）。
  - CLI 生成コードは grant 種別でガード済み。
- 不足している可能性があること
  - 初回認証で acr / amr が確定しなかったセッションの refresh では、
    core API 単体だと resolver が再実行される。
    「refresh では resolver を呼ばない」という不変条件が、呼び出し側の規律にしか存在しない。

## 6. 改善・追加を検討する理由

ユーザーの現在のアカウント状態から acr / amr を導出する resolver
（例: MFA 登録済みなら LoA2 を返す実装）を考える。
パスワードのみでログインしたユーザーが後から MFA を登録すると、
次の refresh は再認証なしで `amr: ["pwd","otp"]` 相当の ID Token を生む。
RFC 9470 のように acr を認可判断へ使う RP は、MFA 認証されていないセッションに
昇格アクセスを与えることになる。

生成コード側にガードがある以上、既定構成の実害は無い。
core を直接使う利用者（このライブラリの想定ユースの一つ）に対して、
不変条件を API で表現するか、契約として文書化するかの判断が要る。

## 7. 実装方針の候補

1. **grant 種別を入力に加える**
   `ResolveAcrAmrInput` に `grantType`（または `suppressResolver` 相当）を追加し、
   refresh のとき resolver を呼ばない判断を core に置く。
   API 変更になるため、後方互換の扱い（optional にして未指定は従来挙動）を決める必要がある。
2. **認証コンテキストを三値で表現する**
   「resolver が判断済みで acr 無し」と「未解決」を区別できる形
   （例: 保存側に解決済みフラグを持つ）にして、解決済みなら値が無くても resolver を飛ばす。
   ストア形式に波及するため影響範囲が広い。
3. **契約の文書化のみ**
   `resolveAcrAmr` / `generateTokenResponse` の JSDoc に
   「refresh では acrResolver を渡さないこと」を明記し、生成コードと同じ規律を利用者に求める。
   実装変更なしで済むが、防御は規律頼みのままになる。

どの案を採るかで API とストアへの影響が変わるため、人間の判断を待ってタスク化する。

## 8. タスク案

方針決定後に切り出す。
候補: 「refresh_token grant で acrResolver を再実行しない不変条件を core に実装する」
（対象: `packages/core/src/token-response.ts`、`token-response-steps.test.ts`、
方針 1 なら CLI テンプレートの呼び出し整合も確認）。
