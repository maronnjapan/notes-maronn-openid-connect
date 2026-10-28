# 理解資料: Rich Authorization Requests（rar）

この資料は、プロジェクト所有者が RAR 機能を正確に理解するためのもので、仕様書の要約ではない。
RFC 9396 の考え方と、このリポジトリの構造への対応付けを説明する。

## 解決する問題

`scope` は空白区切りの文字列の集合で、認可の粒度が「API 全体」や「操作の種類」で止まる。
「口座 X から 123.50 ユーロを 1 回だけ送金する」のような要求を scope で表すには、値の中に構造を埋め込む独自規約（`payment:123.50:EUR` のような文字列）を発明するしかなく、相互運用できない。

**Rich Authorization Requests（RAR）** は、この構造を `authorization_details` という JSON 配列パラメータとして標準化した。
各要素は `type` フィールドで意味を宣言するオブジェクトで、金額、口座、操作、期間のような型固有フィールドを持てる。
OP の仕事は、要素を検証し、ユーザーに見せ、承認された内容をトークンと一緒に資源サーバーへ届けることである。

## 背景標準

- **RFC 9396**（2023-05、Proposed Standard）が本体。パラメータの構造（§2）、認可リクエストでの使い方（§3）、エラー（§5）、トークンリクエスト（§6）とレスポンス（§7）、資源サーバーへの伝達（§9）、メタデータ（§10）を定める。
- FAPI 2.0 Security Profile（Final、2025-02）は、`scope` で表現しきれない認可に RAR の使用を推奨する（非規範ノート。要件ではない）。
- IANA に type のレジストリがあるが、type の意味論は API ごとのプロファイルが決める。RFC 9396 自体はどの type も定義しない。

## 基礎概念

- **authorization details オブジェクト**: `type` を必ず持つ JSON オブジェクト。共通フィールド（`locations` / `actions` / `datatypes` / `identifier` / `privileges`）はすべて任意で、型固有フィールドを自由に足せる。
- **type**: オブジェクトの意味と許されるフィールドを決める識別子。OP は自分が理解する type だけを受理しなければならない（§5）。「理解する」の中身は OP 運用者が決めるので、本機能では型定義（validator と同意表示文の生成関数）を注入する形にした。
- **fail-closed**: 未知 type、構造違反、上限超過はすべて `invalid_authorization_details` で拒否する。黙って無視すると、クライアントは「要求が通った」と誤認したまま同意のない権限を期待してしまう。

## 登場人物

- **クライアント**: `authorization_details` を組み立てて認可リクエストに載せる。
- **OP（本リポジトリ）**: 検証、同意表示、保持、応答への反映を行う。
- **エンドユーザー**: 同意画面で scope と details の両方を見て承認する。
- **資源サーバー**: introspection の `authorization_details` member で、トークンに紐づく詳細な権限を知る。
- **OP 運用者**: 受理する type とその検証・表示を型定義として注入する。

## 通常フロー

1. クライアントが `authorization_details`（URL エンコードされた JSON 配列）付きで `/authorize` へ。
2. OP が構造検証と型定義の検証を行い、トランザクションに保持する。
3. ログイン後、同意画面に scope と details の表示行が併記される。
4. 承認すると、details が認可の grant に紐づく。
5. トークン応答に `authorization_details` が含まれる（RFC 9396 §7 の MUST）。
6. refresh しても同じ details が引き継がれて返る。
7. 資源サーバーが introspection を呼ぶと、`active: true` の応答に `authorization_details` が top-level で現れる。

## 失敗フロー

- 不正な JSON、未知 type、上限超過 → `error=invalid_authorization_details` でクライアントへリダイレクト。
- `prompt=none` と details の併用 → `error=consent_required`。details は毎回ユーザーの同意を要するという本機能のポリシーによる。`none` が他の prompt 値と組むリクエストはもともと OIDC Core 違反なので、本機能は手を出さず、base の検査が従来どおり `invalid_request` で拒否する。
- トークンリクエストに `authorization_details` を載せる → 400 の `invalid_authorization_details`。narrowing（§6）は非対応で、黙殺せず明示拒否する。拒否はトークンの発行・保存やリフレッシュトークンのローテーションが起きる前のステップで確定する。id-jag や token-exchange など他機能が応答する grant では、各機能の既存拒否（`invalid_request`）が先に効く。
- 型定義が一つも設定されていない OP へ details を送る → すべて拒否。discovery に `authorization_details_types_supported` が無いことが「送るな」の合図になる（§10）。

## セキュリティモデルと脅威対策

- **同意の迂回**: scope 単位の同意記録（`consentResolver.hasConsent`）は details を知らない。SSO で同意がスキップされると、ユーザーが見ていない金額や口座が grant に紐づく。本機能は details があるとき `prompt` に `consent` を加え、すべての経路を同意画面へ通す。
- **機微情報の漏えい**: details は金額や口座を含みうる。ログに出さず、`error_description` にも反映しない（リファラやログ経由の漏えい面を作らない。§13）。
- **インジェクション**: details は不透明な JSON 値として保持・転記だけを行い、深いマージや動的キー書き込みをしない（§12 の sanitize 要求への答え）。`__proto__` キーを持つ入力も own property のまま運ばれ、プロトタイプへ届かない。
- **DoS**: バイト長（UTF-8 基準 16 KiB 既定）と要素数（16 既定）の上限で、巨大な JSON のパースを入口で止める。
- **改ざん**: パラメータの完全性保護は本機能では足さない。必要なら request object（署名付き）や PAR と併用する（§12 の示唆どおり）。

## リクエスト・レスポンス実例

認可リクエスト（改行は読みやすさのため）:

```text
GET /authorize?response_type=code
  &client_id=example-client
  &redirect_uri=https%3A%2F%2Fclient.example%2Fcb
  &scope=openid
  &code_challenge=...&code_challenge_method=S256
  &authorization_details=%5B%7B%22type%22%3A%22payment_initiation%22%2C
    %22actions%22%3A%5B%22initiate%22%5D%2C
    %22instructedAmount%22%3A%7B%22currency%22%3A%22EUR%22%2C%22amount%22%3A%22123.50%22%7D%7D%5D
```

デコード後の `authorization_details`:

```json
[
  {
    "type": "payment_initiation",
    "actions": ["initiate"],
    "instructedAmount": { "currency": "EUR", "amount": "123.50" }
  }
]
```

トークン応答:

```json
{
  "access_token": "...",
  "token_type": "Bearer",
  "expires_in": 3600,
  "refresh_token": "...",
  "id_token": "...",
  "authorization_details": [
    {
      "type": "payment_initiation",
      "actions": ["initiate"],
      "instructedAmount": { "currency": "EUR", "amount": "123.50" }
    }
  ]
}
```

introspection 応答（抜粋）:

```json
{
  "active": true,
  "scope": "openid",
  "client_id": "example-client",
  "authorization_details": [ { "type": "payment_initiation", "...": "..." } ]
}
```

## データ構造

- **AuthorizationDetail**: §2 のオブジェクトをそのまま表す型。型固有フィールドはインデックスシグネチャで不透明に持つ。
- **AuthorizationDetailTypeDefinition**: 運用者が注入する型定義。`validate` が型固有の検証、`describe` が同意画面の表示行を作る。
- **RarDetailsStore**: transactionId 用と grantId 用の 2 インスタンスで使う in-memory ストア。認可の途中（同意前）は transactionId に、承認後は grantId に details がぶら下がる。

## 用語集

- **RAR**: Rich Authorization Requests。RFC 9396 の通称。
- **authorization details**: `authorization_details` パラメータの中身である型付きオブジェクトの配列。
- **型定義**: 本機能が導入する、type ごとの validator と表示文生成の組。RFC の用語ではなく、§5 の「理解する type だけ受理せよ」を実装へ落とした形。
- **grant**: 認可コードから始まり refresh で継続する一連のトークン発行の単位。リポジトリでは `grantId` で追跡される。

## core機能・類似機能との違い

- **scope**: 粒度が荒い文字列集合。RAR は構造化オブジェクトで、両者は併存できる（§3.1）。本機能でも `openid` scope は従来どおり必須。
- **claims パラメータ（OIDC Core §5.5）**: ID Token / UserInfo に載せる「属性」の要求であり、API への「権限」の要求ではない。
- **PAR**: リクエストの渡し方の拡張で、RAR は中身の拡張。併用でき、長大な details には PAR が推奨される（§11.4 の示唆）。
- **token-exchange / id-jag**: どちらも `authorization_details` を明示拒否している。これは各仕様（ID-JAG）の要求で、本機能と矛盾しない。RAR は認可コードフローの grant だけに details を紐づける。

## Experimentalにする理由

type の意味論が API プロファイル依存で、OP 単体では「正しい実装」が閉じない。
型定義インタフェースの形（validate / describe で足りるか、比較関数が要るか）は利用者の検証を経てから core 昇格を判断したい。
保持も in-memory の副ストアで始める割り切りがあり、core の型拡張（昇格時の本筋）とは実装形が異なる。

## 誤解しやすい点

- **「details はトークンリクエストでも送れる」**: RFC 上は §6 で narrowing に使えるが、本機能は非対応で、送ると拒否される。黙って無視される訳ではない。
- **「未知 type は無視される」**: されない。§5 の MUST refuse に従い全体が拒否される。
- **「details があれば scope は不要」**: このリポジトリの OP は OIDC Provider であり、`openid` scope は常に必須のまま。
- **「introspection の details は資源サーバーごとに絞られる」**: v1 では絞らず、grant に紐づく全体を返す。
- **「enriched details（§7.1）が返ることがある」**: 本機能は要求をそのまま返すだけで、拡充しない。
- **「device フローや CIBA でも使える」**: §3 は拡張適用を認めるが、v1 は認可コードフローのみ。他のエンドポイントではパラメータは従来どおり無視される。

## 実装後の利用方法

```bash
# 生成
npx maronn-oidc generate hono --enable rar

# 型定義の注入（生成コードの設定で）
# rarTypes に { type, validate, describe } を登録すると
# discovery に authorization_details_types_supported が現れる
```

型定義を登録した type だけが受理される。
登録が空のままなら、`authorization_details` 付きのリクエストはすべて `invalid_authorization_details` になる。

## 一次資料の読み方ガイド

- RFC 9396 は §2（構造）→ §3 と §5（認可リクエストと拒否）→ §7（トークン応答の MUST）→ §9.2（introspection）→ §10（メタデータ）の順に読むと、本機能のスコープがそのまま追える。
- §6 と §6.1（トークンリクエストでの narrowing と比較）、§7.1（enrichment）、§9.1（JWT AT claim）は本機能の非目標なので、「何をやらないか」を確かめる読み方になる。
- 小文字の should / can が多い RFC で、MUST は §2 の type REQUIRED、§5 の refuse、§7 の応答、§9.2 の member 構造、§12 の sanitize に集中している。

## 昇格判断の観点

- 型定義インタフェース（validate / describe）が実利用で足りたか。比較（§6.1）や資源サーバー別フィルタの需要が出たか。
- 副ストアではなく core の型拡張（トランザクション、コード、トークン情報への `authorizationDetails` フィールド）へ移す価値が確認できたか。
- JWT AT への claim 追加（§9.1 RECOMMENDED）と FAPI 2.0 構成（PAR + RAR）での conformance 需要。
