# 理解資料: RP-Initiated Logout（rp-initiated-logout）

仕様書の要約ではなく、この機能が本リポジトリのどこに、なぜこの形で入るのかを説明する資料。

## 解決する問題

本 OP はログインと同意を実装済みだが、ログアウトの経路が存在しない。
End-User が RP からログアウトしても OP のブラウザセッションは残り続け、次の認可リクエストは再認証なしで通ってしまう。
SSO 構成の検証では「ログアウトが要件どおり波及するか」がログインと同じ重みで問われるため、この空白は「自分の要件がこの仕様で実現できるか」を検証するという本ライブラリのコンセプトに対する欠落である。

RP-Initiated Logout 1.0 は、この「RP から OP セッションを終了させる」経路だけを定義する最小のログアウト仕様である。
他 RP への伝播（Front-Channel / Back-Channel Logout）はこの仕様の外にあり、本機能でも対象外とする。

## 背景標準

- **OpenID Connect RP-Initiated Logout 1.0**（Final, 2022-09-12）: 本機能の準拠仕様。`end_session_endpoint` の定義そのもの
- **OpenID Connect Core 1.0**: `id_token_hint` の元になる ID Token の定義。検証規則（iss / aud / 署名）は Core §2 と §3.1.3.7 の流用
- **OpenID Connect Discovery 1.0**: `end_session_endpoint` メタデータの公表先
- 関連するが対象外: Session Management 1.0（iframe 監視）、Front-Channel Logout 1.0、Back-Channel Logout 1.0（他 RP への伝播）

ログアウト系 4 仕様のうち RP-Initiated だけが「RP → OP」の一方向で完結し、他の 3 つは OP から RP への通知チャネルを必要とする。
この非対称が、RP-Initiated だけを experimental の 1 機能として切り出せる理由になっている。

## 基礎概念

**end_session_endpoint** は、RP がユーザーエージェントごと OP に遷移させるエンドポイントである。
authorize と同じフロントチャネル（ブラウザのリダイレクト）で動き、バックチャネル API ではない。
だから応答は JSON ではなく HTML 画面とリダイレクトになる。

**id_token_hint** は「このユーザーとしてログアウトしたい」という主張の証拠である。
過去に OP が発行した ID Token をそのまま渡すことで、OP は署名検証だけで「この RP がこの End-User にトークンを発行された当人である」ことを確認できる。
新しいトークン発行や認証は要らない。

**確認画面**は、証拠のないログアウト要求からユーザーを守る仕組みである。
有効な `id_token_hint` がない要求を無条件に実行すると、`<img src="https://op/logout">` を踏ませるだけで被害者のセッションを終了させられる（仕様 §7 が明記する DoS）。
だから仕様は「ヒントがない、または現在のセッションのものでない場合、ユーザーに確認しなければならない（MUST）」と定める。

**post_logout_redirect_uri** は authorize の `redirect_uri` と同じ構造の危険を持つ。
検証なしで受け入れると、OP がオープンリダイレクタになる。
仕様は「事前登録された値との完全一致」だけを許す（MUST NOT の裏返し）。

## 登場人物

| 役割 | 本リポジトリでの対応物 |
|---|---|
| End-User | ブラウザセッション（`session_id` Cookie と browser session store）を持つユーザー |
| RP | `tests/e2e/apps` のクライアントアプリ。ログアウトリンクの遷移元 |
| OP | CLI 生成コード。`/logout` ルートと画面を持つ |
| 検証ロジック | `@maronn-openid-connect/experimental/rp-initiated-logout` の純関数群と core の `validateIdTokenHint` |

## 通常フロー

1. RP がログアウトリンク（`GET /logout?id_token_hint=...&post_logout_redirect_uri=...&state=...`）へユーザーを遷移させる
2. 生成コードがパラメータを正規化し（`parseEndSessionRequest`）、ヒントの期待 aud を特定する（`client_id` パラメータ、なければ `extractIdTokenHintAudience`）
3. core の `validateIdTokenHint` が署名・iss・aud・exp を検証する
4. `decideLogoutFlow` がヒントの `sub` と現在セッションの subject を照合し、一致すれば即時ログアウトを選ぶ
5. 生成コードが browser session store の `delete` と Cookie 破棄を行う
6. `resolvePostLogoutRedirect` が登録 URI との完全一致を確認し、`state` 付きの URL を返す
7. 302 で RP に戻る。RP は `state` で自分のリクエストと突き合わせる

## 失敗フロー（確認画面の経路）

ヒントなし、検証失敗（期限切れを含む）、`client_id` 不一致、セッション不在、`sub` 不一致は、すべて同じ確認画面に落ちる。
理由を画面に出さないのは、失敗理由の差がセッション状態や他ユーザーの情報を漏らすオラクルになるためである。
確認画面で End-User が承認の POST（CSRF cookie 付き）を送って初めてセッションが消える。
承認せず離脱すれば何も変わらない。

## セキュリティモデルと脅威対策

この機能の攻撃面は「未認証で叩ける」「リダイレクトする」の 2 点に集約される。

- **強制ログアウト（DoS）**: リンクを踏ませるだけの攻撃は確認画面で止まる。即時ログアウトには被害者本人の ID Token が必要で、それを持つ攻撃者はヒント検証を通せるが、`sub` がセッションと一致するのは被害者本人のブラウザだけなので、他人のブラウザのセッションは消せない
- **オープンリダイレクト**: リダイレクトは検証済みクライアントの登録値と完全一致した場合だけ。ヒントが無効なら一致しても飛ばさない。正規化やプレフィックス一致を入れないのは、authorize の `redirect_uri` 検証と同じ判断
- **確認画面への CSRF**: 承認 POST を偽造されると確認画面の意味がなくなるため、Device / CIBA の approve と同じ per-flow CSRF cookie で守る
- **state の反射**: `state` は解釈せず URL API のクエリ付加でのみ出力するため、URL エンコードを通らずに応答へ出る経路がない

## リクエスト・レスポンス実例

即時ログアウトとリダイレクト:

```text
GET /logout?id_token_hint=eyJhbGciOiJSUzI1NiIs...&post_logout_redirect_uri=https%3A%2F%2Frp.example%2Floggedout&state=af0ifjsldkj
Cookie: session_id=abc123

HTTP/1.1 302 Found
Location: https://rp.example/loggedout?state=af0ifjsldkj
Set-Cookie: session_id=; Max-Age=0; HttpOnly; Secure; SameSite=Lax; Path=/
```

ヒントなし（確認画面）:

```text
GET /logout

HTTP/1.1 200 OK
Content-Type: text/html
（「OP からログアウトしますか？」の確認フォーム。セッションはまだ消えていない）
```

discovery:

```json
{
  "issuer": "http://localhost:3000",
  "end_session_endpoint": "http://localhost:3000/logout"
}
```

## データ構造

- `EndSessionRequest`: 6 パラメータの正規化結果。experimental の入口型
- `LogoutDecision`: `requiresConfirmation`（画面分岐）と `verifiedClientId`（リダイレクト権限の主体）の 2 値。ルートの分岐はこの型だけを見る
- `rpInitiatedLogoutConfig.postLogoutRedirectUris`: `Record<client_id, string[]>`。生成コード側の登録簿で、core の `ClientInfo` は変更しない

## 用語集

- **RP-Initiated**: ログアウトの起点が RP であること。OP の画面から自発的にログアウトする経路（OP-initiated）はこの仕様の対象外
- **end_session_endpoint**: discovery で公表するログアウトエンドポイントの標準名。パスは OP の自由（本機能は `/logout`）
- **post_logout_redirect_uri**: ログアウト完了後の戻り先。authorize の `redirect_uri` とは別に登録する
- **logout_hint**: ログアウト対象ユーザーのヒント（OPTIONAL）。本機能は受理するが使わない

## core機能・類似機能との違い

- **prompt=login との違い**: `prompt=login` は再認証を強制するがセッションは残る。本機能はセッションそのものを消す
- **revocation（RFC 7009）との違い**: revocation はトークン単位の失効で、セッションに触れない。本機能はセッション単位で、トークンには直接触れない。online refresh token が使えなくなるのは、セッション消滅を core の `AuthenticationSessionResolver` が `null` で報告する既存機構の帰結であり、本機能がトークンを失効させるのではない
- **実装済み experimental 6 機能との違い**: 既存 6 機能はすべてトークン発行系（token エンドポイントか authorize の応答形式）で、セッションのライフサイクルに触れる機能は本機能が初

## Experimentalにする理由

確認画面の省略条件（有効ヒント時にスキップ）は SHOULD の解釈であり、利用者の要件次第で「常に確認」「確認なし構成」が欲しくなり得る。
登録 URI を experimental 設定オブジェクトに置く形も、core の `ClientInfo` へ寄せる再設計があり得る。
どちらも公開 API の形が利用者フィードバックで変わり得るため、安定 API の core には入れない。

## 誤解しやすい点

- 「ログアウトすればトークンも無効になる」は誤り。offline refresh token とアクセストークンは残る。消えるのはセッションと、セッション束縛の online refresh token だけ
- 「post_logout_redirect_uri は redirect_uri の登録を流用できる」は誤り。仕様上も本実装上も別の登録簿であり、未登録なら完了画面に落ちる
- 「期限切れ ID Token でもログアウトできる」は本実装では部分的にしか正しくない。仕様の SHOULD は受理を勧めるが、本実装は確認画面の経路に落とす（確認を経ればログアウト自体はできる）
- 「確認画面が出た = 攻撃された」は誤り。ヒントの期限切れや別ブラウザでの操作でも正常に確認画面へ落ちる

## 実装後の利用方法

```bash
npx @maronn-openid-connect/cli generate --enable rp-initiated-logout
```

生成された設定の `rpInitiatedLogoutConfig.postLogoutRedirectUris` に RP のクライアント ID と戻り先 URI を登録し、RP のログアウト処理で `end_session_endpoint` へ遷移させる。
discovery（`/.well-known/openid-configuration`）の `end_session_endpoint` を読めば、RP 側ライブラリの自動設定も動く。

## 一次資料の読み方ガイド

RP-Initiated Logout 1.0 は本文 4 ページ強の短い仕様で、§2（ロジック本体）、§3（リダイレクト規則）、§7（Security Considerations）だけ読めば実装判断はすべて追える。
§2 で MUST / SHOULD / RECOMMENDED の別に注意して読むと、本仕様書の判定規則の各行が §2 のどの文に対応するかが分かる。
「RP への通知が終わってからリダイレクトする」という一文は Front/Back-Channel Logout の実装を前提にした記述で、本機能では通知対象がないため通知フェーズは空になる。

## 昇格判断の観点

- 確認画面の判定規則が利用者フィードバックで安定したか（構成値の要望が出なかったか）
- 登録 URI の置き場所を `ClientInfo` に寄せる必要が出たか
- Front-Channel / Back-Channel Logout の実装計画が具体化し、`sid` クレーム発行（core 変更）との一体設計が必要になったか
- `study-material/ext-rp-initiated-logout.md` の方針 A（core の純関数 + `ClientInfo` 拡張）へ移植する際の互換性
