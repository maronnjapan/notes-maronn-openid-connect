# 理解資料: JWT Response for OAuth Token Introspection (RFC 9701)

この資料は、プロジェクト所有者が `jwt-introspection-response` 機能を仕様書なしで正確に理解するためのものである。
仕様の要約ではなく、このリポジトリの実装への対応付けを説明する。

## 解決する問題

Token Introspection（RFC 7662）の応答は素の JSON である。
Resource Server（RS）は TLS の接続先が正しいことだけを根拠に応答を信頼しており、応答そのものには出所の証明も改ざん検知の仕組みもない。
マイクロサービス間や TLS 終端が多段のゲートウェイ構成では、経路上のコンポーネントが応答を書き換えても RS には分からない。
さらに、イントロスペクション応答の内容に AS が法的責任を負う構成（RFC 9701 §1 が挙げる、検証済み個人データを証明書発行に使う例）では、「この応答は確かにこの AS が発行した」という否認不可能な証拠が要る。

RFC 9701 はこの問題を、イントロスペクション応答を署名付き JWT として返せるようにすることで解決する。
RS は AS の JWKS 公開鍵で署名を検証し、応答の出所と完全性を暗号的に確認できる。

## 背景標準

- **RFC 7662**（Token Introspection）: 応答の中身（`active` と各属性）を定義する。本リポジトリは core 実装済みで、デフォルト生成対象
- **RFC 9701**（JWT Response for OAuth Token Introspection, 2025-01）: RFC 7662 の応答を JWT で包む方法を定義する。本機能の準拠仕様
- **RFC 7519 / 7515**（JWT / JWS）: 署名形式。compact JWS
- **RFC 8414**（AS Metadata）: `introspection_signing_alg_values_supported` の広告先
- **RFC 8725**（JWT BCP）: `typ` 明示・alg 制限・`kid` の実践

## 基礎概念と登場人物

- **Resource Server（RS）**: アクセストークンを受け取り、イントロスペクションで検証する側。RFC 9701 では JWT 応答の「要求者」であり「検証者」。本 OP では RS を通常のクライアントとして登録する（RFC 9701 §3 が RFC 7591 を使う構成として例示する形）
- **`Accept: application/token-introspection+jwt`**: RS が JWT 応答を要求する手段（§4）。HTTP のコンテントネゴシエーションをそのまま使う
- **`token_introspection` クレーム**: RFC 7662 の応答ボディを丸ごと収める入れ物（§5）。属性をトップレベルに展開しないのは、`sub` や `scope` が JWT の同名トップレベルクレームと衝突・混同することを防ぐため
- **`typ: token-introspection+jwt`**: この JWT が「イントロスペクション応答」であってアクセストークンでも ID トークンでもないことの型表明（§5 / §8.1）

## 通常フロー（このリポジトリの生成 OP で起きること）

1. RS がクライアント認証付きで `POST /introspect` を送る。`Accept: application/token-introspection+jwt` を付ける
2. 生成コードの既存パイプラインがそのまま動く: クライアント認証 → `token` 必須検査 → トークン解決 → active 判定 → 属性構築。ここまで本機能は関与しない
3. 応答構築の直前で `Accept` を判定する。JWT 要求があれば、まず呼び出し元 audience 制限（後述）を応答に適用する
4. 制限適用後の応答を `token_introspection` クレームに収め、`iss`（OP の issuer）・`aud`（呼び出し元 client_id）・`iat` を付け、`typ: token-introspection+jwt` / `alg: RS256` / `kid` のヘッダーで署名する
5. `Content-Type: application/token-introspection+jwt` で compact JWS を返す
6. RS は JWKS から `kid` の公開鍵を取り、署名検証 → `typ` 確認 → `iss` / `aud` 確認 → `token_introspection.active` を読む

`Accept` を付けない従来のリクエストは手順 2 のあと従来どおり JSON で返り、本機能は一切関与しない。

## 失敗フロー

- **無効・期限切れ・失効トークン**: JWT 要求時も 200 で JWT が返り、`token_introspection` は `{ "active": false }` のみになる（§5）。JSON 時の `{ active: false }` と同じ情報量
- **呼び出し元が権限外**（トークンの発行先でも `aud` 記載先でもない）: 同じく `{ "active": false }` に落ちる。理由は応答から区別できない
- **クライアント認証失敗**: `Accept` の値によらず、既存どおり JSON の `invalid_client`（401）。JWT 化されない
- **RS256 鍵が署名鍵セットに無い**: 鍵選択が例外を投げ、既存の catch で `server_error`（500）。誤った alg で署名された JWT が返ることはない

## セキュリティモデルと脅威対策

本機能の中心的な脅威は **cross-JWT confusion**（§8.1）である。
イントロスペクション JWT は `iss` が OP で `aud` がクライアントという、アクセストークンや ID トークンと似た形をしている。
攻撃者がイントロスペクション JWT をアクセストークンとして RS に提示する置き換え攻撃に対し、仕様は 3 つの構造的対策を定めており、本機能はそのまま実装する:

1. `typ: token-introspection+jwt` の型表明（RS は受け取ったすべての JWT でこれを検証しなければならない）
2. `sub` / `scope` 等の属性を `token_introspection` に封入し、トップレベルへ展開しない
3. トップレベルに `sub` / `exp` を含めない（アクセストークンとして最低限必要なクレームを欠けさせる）

第二の脅威は**認証なしダウングレード**（§8.2）である。
RFC 7662 は匿名でのイントロスペクションを許す余地があるが、RFC 9701 準拠 AS は認証なしの呼び出しを拒否しなければならない。
本 OP のイントロスペクションエンドポイントは元からクライアント認証必須であり、この要件は既存挙動で満たされている（ステータスコードが仕様の 400 でなく既存の 401 である相違は「誤解しやすい点」を参照）。

第三の脅威は**権限外トークンの偵察**である。
RFC 9701 §3 は「AS は RS がそのトークンの audience かを判定できなければならない」とし、判定方法は AS の裁量に委ねる。
本機能は「呼び出し元がトークンの発行先クライアント本人、またはトークンの `aud` に含まれる場合のみ開示」を JWT 応答経路の既定とする。
JSON 経路は互換のため従来どおり（認証済みクライアントなら開示）で、この面の強化は core 側のフックタスク（`tasks/p3-introspection-caller-authorization-hook.md`）の責務として残る。

## リクエスト・レスポンス実例

リクエスト:

```http
POST /introspect HTTP/1.1
Host: localhost:3000
Accept: application/token-introspection+jwt
Content-Type: application/x-www-form-urlencoded
Authorization: Basic aW50cm9zcGVjdGlvbi1yczpzZWNyZXQ=

token=2YotnFZFEjr1zCsicMWpAA
```

応答:

```http
HTTP/1.1 200 OK
Content-Type: application/token-introspection+jwt
Cache-Control: no-store
Pragma: no-cache

eyJ0eXAiOiJ0b2tlbi1pbnRyb3NwZWN0aW9uK2p3dCIsImFsZyI6IlJTMjU2Iiwia2lkIjoia2V5LTEifQ.eyJpc3MiOi...（compact JWS）
```

JWT ヘッダー（デコード後）:

```json
{ "typ": "token-introspection+jwt", "alg": "RS256", "kid": "key-1" }
```

JWT ペイロード（デコード後）:

```json
{
  "iss": "http://localhost:3000",
  "aud": "introspection-rs",
  "iat": 1787000000,
  "token_introspection": {
    "active": true,
    "client_id": "demo-client",
    "scope": "openid profile",
    "sub": "user1",
    "token_type": "Bearer",
    "exp": 1787000600
  }
}
```

`token_introspection` の中の `sub` / `exp` はトークンの属性（RFC 7662 の応答メンバー）であり、JWT トップレベルには存在しないことに注意。

## データ構造

新しい永続データはない。
本機能はストア契約を追加せず、既存のイントロスペクション解決（アクセストークン / リフレッシュトークンの resolver）の出力を包むだけである。
公開 API は純関数 3 つ（`Accept` 判定・audience 制限・JWT 生成）で、状態を持たない。

## core 機能・類似機能との違い

- **core のイントロスペクション（RFC 7662）との関係**: 本機能は core の判定結果を一切変えない。core が active と言えば active、inactive と言えば inactive で、変わるのは「呼び出し元が権限外のとき JWT 経路では inactive に落とす」ことと応答の外装だけ
- **JARM との対比**: どちらも「既存応答を署名付き JWT に変換する」機能で、実装パターン（RS256 固定・kid 付き・Web Crypto 自前 compact JWS・条件付き補間）を共有する。違いは対象で、JARM はフロントチャネルの認可レスポンス（リダイレクト URL の `response` パラメータ）、本機能はバックチャネルのイントロスペクション応答（HTTP ボディ）である。また JARM の JWT は `exp` を持つ（リダイレクトの一回性を守る）が、本機能の JWT は `exp` を持たない（§5 SHOULD NOT。アクセストークン悪用防止のため意図的に欠けさせる）
- **UserInfo の署名応答（`generateUserInfoJwt`）との対比**: core に既にある「エンドポイント応答の JWT 化」の先例で、構造はほぼ同型。違いは `typ`（UserInfo は `JWT`、本機能は `token-introspection+jwt`）と、クレームの封入（UserInfo はトップレベル展開、本機能は `token_introspection` に封入）

## Experimental にする理由

- `Accept` ネゴシエーションの解釈（完全一致のみ・q 値無視）は本仕様の設計判断で、利用者フィードバックで変わり得る
- audience 制限の既定ポリシーは RS 構成に依存して差し替え要望が出る可能性が高く、公開 API の形が固まっていない
- core の `canIntrospect` フックが将来入ると、制限ロジックの置き場所を見直す再設計があり得る

## 誤解しやすい点

- **「JWT が返る＝トークンが有効」ではない**。無効トークンでも 200 で JWT が返り、`token_introspection.active` が false になる。有効性は必ず `active` で判定する
- **イントロスペクション JWT はアクセストークンではない**。形が似ているが、`typ` が違い、`sub` / `exp` がトップレベルに無い。RS が JWT 形式のアクセストークンを使う構成では、`typ` 検証を実装しないと置き換え攻撃が成立し得る（§8.1。これを手元で確認できるのが本機能の検証価値でもある）
- **`Accept: */*` では JWT にならない**。汎用 HTTP クライアントの既定値で応答形式が変わらないよう、明示的なメディアタイプ一致のみを JWT 要求と解釈する
- **認証失敗は 401 のまま**。RFC 9701 §5 の Note は認証なし呼び出しへ 400 を返すと書くが、本 OP は RFC 7662 系の既存挙動（`invalid_client` 401）を維持する。「認証なしにデータを開示しない」という要件の実質は満たしている
- **JSON 経路の開示範囲は変わらない**。audience 制限は JWT 応答だけに働く。JSON で従来できた「他クライアント宛トークンのイントロスペクション」は従来どおり可能で、その強化は別タスクの責務

## 実装後の利用方法

```bash
# JWT イントロスペクションレスポンス有効の OP を生成
npx @maronn-openid-connect/cli generate --framework hono --enable jwt-introspection-response

# RS 側（curl での確認例）
curl -s http://localhost:3000/introspect \
  -H 'Accept: application/token-introspection+jwt' \
  -u introspection-rs:secret \
  -d 'token=<access_token>'
# → compact JWS が返る。JWKS (http://localhost:3000/.well-known/jwks.json) で検証する
```

`--enable jwt-introspection-response` は introspection 機能を前提とするため、`--disable introspection` と同時指定すると生成前にエラーで止まる。

## 一次資料の読み方ガイド

- RFC 9701 は本文 10 ページ弱で、§4（要求方法）と §5（JWT の構造）だけで実装要件のほぼ全てが決まる。まず §5 の非規範例（JWT のヘッダー・ペイロード実例）を見てから規範文を読むと速い
- §3（Resource Server Management）は「AS は RS を認証・認可できなければならない」という前提条件の章で、具体的な実装方法は裁量。本機能がどの裁量を選んだかは仕様書の「audience 制限」の節と対応付けて読む
- §6（Client Metadata）と §7（AS Metadata）のパラメータ群は大半が OPTIONAL。本機能が出力するのは `introspection_signing_alg_values_supported` のみで、他を出さないことも仕様適合である
- §8.1（Cross-JWT Confusion）は RS 側の実装要件（受信 JWT の `typ` 検証）も含む。OP 実装だけでなく RS を書く利用者向けの注意として読む

## 昇格判断の観点

- `Accept` 判定・audience 制限の既定ポリシーに対する利用者フィードバックが安定しているか
- core の `canIntrospect` フック（別タスク）の実装状況と、制限ロジックの置き場所の最終判断
- `createIntrospectionResponseJwt` を core の `generateUserInfoJwt` と並ぶ core 関数として移植する価値（調査資料の候補 A の形）が実証されたか
- 暗号化レスポンス（JWE）要望の有無と、JWE 基盤の方針確定
