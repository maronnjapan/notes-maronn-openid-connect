# 理解資料: JWT Secured Authorization Response Mode (JARM)

この資料は、プロジェクト所有者が JARM を正確に理解し、本リポジトリへの導入判断・レビュー・実装確認を行えるようにするためのものである。仕様書（specification.md）の要約ではなく、「JARM とは何か」を本リポジトリの実装に対応付けて説明する。

## 解決する問題

現在の生成 OP は、認可レスポンスを**平文のクエリパラメータ**で返す:

```text
302 Found
Location: https://client.example.com/cb?code=abc123&state=xyz&iss=http://localhost:3000
```

この形式には次の構造的な弱点がある:

1. **完全性が保護されない**: リダイレクトはブラウザを経由するため、途中で `code` や `state` が差し替えられてもクライアントは検知できない（改竄・注入攻撃）
2. **出所が証明されない**: レスポンスがどの認可サーバーから来たのかをパラメータだけでは暗号学的に確認できない。複数の OP と連携するクライアントでは、悪意ある OP が別の OP の応答になりすます **mix-up 攻撃**（RFC 9700 §4.4）が成立し得る。現在は RFC 9207 の `iss` パラメータで issuer を平文表明しているが、これ自体も改竄可能である

JARM は認可レスポンス全体を **OP が署名した JWT** に変えることで、この 2 つを同時に解決する。クライアントは JWT の署名を OP の `jwks_uri` の公開鍵で検証し、`iss` / `aud` クレームで「正しい OP からの・自分宛の応答」であることを確認してから `code` を使う。

## 背景標準

| 仕様 | 役割 |
|---|---|
| JARM（OpenID Foundation, Final 2022-11-09） | 本機能の主仕様。応答 JWT のクレーム構造（§2.1）・署名/暗号化（§2.2）・response_mode 値（§2.3）・クライアント処理規則（§2.4）・メタデータ（§3, §4）を定義 |
| OAuth 2.0 Multiple Response Type Encoding Practices | `response_mode` パラメータそのものの定義（§2.1）。JARM は既存の `query` / `fragment` / `form_post` モードに `.jwt` 系の 4 値を追加する拡張 |
| RFC 6749 / OIDC Core 1.0 | 認可レスポンスのパラメータ（code / state / error）自体の定義。JARM はこれらを JWT クレームに詰め替えるだけで、意味は変えない |
| RFC 9700（OAuth 2.0 Security BCP） | mix-up 攻撃と対策の規範（§4.4: クライアントは mix-up 対策 MUST）。§2.1 で issuer 識別の手段として JARM を明示 |
| RFC 9207 | 平文応答の issuer 識別（`iss` パラメータ）。JARM モードでは JWT の `iss` クレームが同じ役割を担う |

## 基礎概念

- **response_mode**: 「認可レスポンスを**どういう運搬方法で**返すか」を指定するパラメータ。`response_type`（何を返すか）とは独立。本 OP は従来この指定を無視し、常に query で返してきた
- **JARM の 4 モード**: `query.jwt` / `fragment.jwt` / `form_post.jwt` / `jwt`（省略形）。`.` の前が運搬方法、`.jwt` が「JWT に包む」ことを表す。`jwt` は response_type ごとのデフォルト運搬方法を意味し、`code` では `query.jwt` になる（§2.3.4）
- **応答 JWT**: `iss`（OP）/ `aud`（client_id）/ `exp`（JWT の期限）＋認可レスポンスパラメータをクレームに持つ署名付き JWT。成功時は `code` / `state`、エラー時は `error` / `error_description` / `state` が入る

## 登場人物

| 役割 | 本リポジトリでの対応物 |
|---|---|
| 認可サーバー（応答 JWT の発行者） | CLI 生成 OP（`samples/*`）＋ `@maronn-openid-connect/experimental/jarm` ＋ core |
| クライアント（応答 JWT の検証者） | 利用者のアプリ。E2E では `tests/e2e/apps` の専用クライアント |
| 署名鍵 | 生成 OP の既存 `signingKeyProvider` の active key（既定では ID Token と同じ RS256 鍵。T-022 の per-purpose 鍵設定で ID Token 用鍵を分けている場合も、JARM は汎用 `signingKeyProvider` の鍵で署名する。`jwks_uri` で公開） |

## 通常フロー

1. クライアントが `GET /authorize?...&response_mode=query.jwt` を送る
2. OP は従来どおり認可リクエストを検証し、redirect_uri 確定後に `response_mode` を解釈。JARM モードであることを auth transaction に記録（`jarmResponseMode: 'query.jwt'`）
3. ログイン・同意は**完全に既存フロー**（JARM は応答の包み方だけの話で、認証・同意には関与しない）
4. code 発行時、OP は `{iss, aud, exp, code, state}` を RS256 署名した JWT を作り、`redirect_uri?response=<JWT>` へ 302
5. クライアントは JWT の署名を `jwks_uri` で検証し、`iss` が期待する OP か・`aud` が自分の client_id か・`exp` が未来かを確認してから `code` を取り出す（§2.4）
6. トークン交換は既存フローと完全に同一（JARM は token endpoint に影響しない）

## 失敗フロー

- **同意拒否など、リダイレクトできるエラー**: `{iss, aud, exp, error: "access_denied", state}` の署名付き JWT を同じく `response` パラメータで返す。エラーであっても署名付きなので、クライアントは「本物の OP が拒否した」ことを検証できる
- **`fragment.jwt` / `form_post.jwt` を要求された**: 本 OP は非対応のため `invalid_request` を**平文クエリ**で返す（対応できないモードでは応答を組めないため。仕様書のバリデーション 3 参照）
- **client_id 不明・redirect_uri 不一致**: 従来どおり非リダイレクトエラー（JSON / HTML）。JARM は「リダイレクトできる応答」の形式なので、リダイレクトしない応答には最初から関与しない

## セキュリティモデルと脅威対策

JARM が守るもの・守らないものを分けて理解することが重要である。

**守るもの**:

- **応答の完全性**: `code` / `state` の差し替えは署名検証で検知される（§5.2）
- **応答の出所**: `iss` クレーム＋署名により mix-up 攻撃を検知できる（§5.3、RFC 9700 §4.4 の対策 1 に相当）
- **宛先の確認**: `aud` クレームにより「他クライアント宛の応答の使い回し」を検知できる

**守らないもの（誤解しやすい）**:

- **code のリプレイ**: 署名は「その JWT が本物か」しか保証しない。同じ JWT を 2 回使う攻撃は `exp`（短命）と、core が既に実装している **code の単回使用**・**PKCE** が防ぐ（§5.2 が PKCE 併用を推奨）
- **code の秘匿**: `query.jwt` の JWT は URL クエリに載るためブラウザ履歴・Referer に残り得る。JWE 暗号化（本機能では非目標）だけがこれを解決する（§5.4）。含まれる機密は短命な code のみで、現行の平文応答と同等（悪化はしない）。PKCE により漏えい code 単独では交換できない

## リクエスト・レスポンス実例

認可リクエスト（変更点は `response_mode` のみ）:

```text
GET /authorize?response_type=code&client_id=my-client
  &redirect_uri=https%3A%2F%2Fclient.example.com%2Fcb
  &scope=openid&state=S8NJ7&nonce=n-0S6
  &code_challenge=E9Mel...&code_challenge_method=S256
  &response_mode=query.jwt HTTP/1.1
```

成功応答（JARM §2.3.1 の実例と同形）:

```text
HTTP/1.1 302 Found
Location: https://client.example.com/cb?response=eyJhbGciOiJSUzI1NiIsImtpZCI6ImtleS0xIn0.eyJpc3MiOi...
```

JWT ペイロード（デコード後。JARM §2.1 の実例と同構造）:

```json
{
  "iss": "http://localhost:3000",
  "aud": "my-client",
  "exp": 1754092860,
  "code": "PyyFaux2o7Q0YfXBU32jhw...",
  "state": "S8NJ7"
}
```

エラー応答の JWT ペイロード:

```json
{
  "iss": "http://localhost:3000",
  "aud": "my-client",
  "exp": 1754092860,
  "error": "access_denied",
  "state": "S8NJ7"
}
```

注意: 成功・エラーとも、`response` 以外のクエリパラメータ（素の `code` / `state` / `iss`）は**付かない**。

## データ構造

| データ | 置き場所 | 内容 |
|---|---|---|
| JARM モードの記録 | auth transaction（`{ ...AuthTransaction, jarmResponseMode?: 'query.jwt' }`） | authorize 時に解釈した応答モード。ログイン・同意を挟いで code 発行時まで store を往復する |
| 応答 JWT | その場で生成（保存しない） | `iss` / `aud` / `exp` ＋応答パラメータ。署名は既存 OP 鍵 |
| discovery 追加フィールド | `/.well-known/openid-configuration` | `response_modes_supported: ['query', 'query.jwt', 'jwt']` / `authorization_signing_alg_values_supported: ['RS256']`（JARM §4） |

新しいストア契約は**追加しない**。ただし auth transaction store（利用者が実装を差し替え可能）が「未知のフィールドを透過的に保存する」ことが前提になる。JSON シリアライズでオブジェクトを丸ごと保存する通常の実装なら自然に満たされるが、フィールドを列挙してコピーする実装だと `jarmResponseMode` が落ち、**平文応答へ静かにフォールバック**する。この前提に依存するのはログイン・同意画面を挟む経路（consent ルートの応答）のみで、prompt=none や SSO 再利用のように authorize ルート内で完結する応答はローカル変数を参照するため影響を受けない。conformance テストの全フローテストがこの round-trip を検出する。

## 用語集

| 用語 | 意味 |
|---|---|
| JARM | JWT Secured Authorization Response Mode。認可レスポンスを署名付き JWT で返す OpenID Foundation の Final 仕様 |
| response_mode | 認可レスポンスの運搬方法を指定するリクエストパラメータ |
| `query.jwt` | JWT をクエリの `response` パラメータで運ぶモード（本機能が対応する唯一のモード） |
| `jwt`（省略形） | response_type ごとのデフォルト JWT モード。`code` では `query.jwt` |
| mix-up 攻撃 | 複数 OP と連携するクライアントに、攻撃者制御の OP が別 OP の応答を混入させる攻撃（RFC 9700 §4.4） |
| `response` パラメータ | JARM 応答 JWT を運ぶ唯一のクエリパラメータ名（§2.3.1） |

## core機能・類似機能との違い

| 機能 | 保護対象 | 方向 |
|---|---|---|
| request-object（JAR, core 実装済み） | 認可**リクエスト**の完全性・出所 | クライアント → OP |
| PAR（experimental 実装済み） | 認可**リクエスト**の機密性・事前検証 | クライアント → OP（バックチャネル） |
| **JARM（本機能）** | 認可**レスポンス**の完全性・出所 | OP → クライアント |
| ID Token | 認証イベントの表明（sub / nonce 等） | OP → クライアント（token endpoint 経由） |

「ID Token があるのに JARM は要るのか」という疑問には注意が必要である。ID Token はトークンレスポンス（code フローではバックチャネル）で得られるもので、**フロントチャネルを通るリダイレクト応答そのもの**は守らない。JARM は code がクライアントに届く時点の保護であり、守る場所が異なる。

## Experimentalにする理由

- 応答リダイレクト構築という生成コードの根幹 6 箇所に条件付き補間で手を入れるため、パターンが安定するまで隔離したい
- auth transaction への拡張フィールド相乗り（store round-trip 前提）が新しい契約であり、実運用フィードバックで固めたい
- alg 追加・JWE・`form_post.jwt`・クライアント別メタデータ対応で公開 API が変わる可能性が高い

## 誤解しやすい点

1. **JARM は暗号化ではない**: 初期実装は署名のみ。JWT ペイロードは base64url デコードすれば誰でも読める。機密性が必要なら JWE（非目標）が必要
2. **JARM は code リプレイを防がない**: 防ぐのは改竄となりすまし。リプレイ対策は従来どおり code 単回使用と PKCE
3. **`jwt` は独立のモードではない**: `response_type=code` では `query.jwt` の別名にすぎない（§2.3.4）
4. **`iss` クエリパラメータは付かない**: JARM モードでは RFC 9207 の素の `iss` パラメータの役割を JWT の `iss` クレームが引き継ぐ。「iss パラメータが消えた」のは仕様どおり
5. **有効化しただけでは何も変わらない**: `--enable jarm` で生成しても、クライアントが `response_mode=query.jwt` を明示しない限り応答は従来の平文クエリのまま（デフォルト挙動不変）
6. **エラーも JWT で返る**: JARM モードのリクエストでは `access_denied` 等のエラーリダイレクトも署名付き JWT になる。クライアント実装はエラーパスでも JWT 検証が必要
7. **store がフィールドを落とすと静かに平文へ戻る**: auth transaction store の独自実装がオブジェクトを丸ごと保存しない場合、JARM モードの記録が失われる。conformance テストで検出できる

## 実装後の利用方法

```bash
# JARM 対応の OP を生成
npx maronn-oidc generate hono --enable jarm
```

クライアント側の最小検証手順（利用者向けドキュメントに記載予定の内容）:

1. 認可リクエストに `response_mode=query.jwt` を付ける
2. コールバックで `response` クエリパラメータを取り出す
3. **先に** JWT の `iss` クレームが期待する OP の issuer と一致することを確認する。JARM §5.1 は「鍵の取得にこの JWT の情報を使う前に、issuer が既知かつ期待どおりであることを確認しなければならない（MUST）」と規定している（細工された `iss` が巨大・低速な JWKS URL を指す DoS への対策。jwks_uri を自分の設定から固定で引く実装でも、この順序にしておくと安全）
4. 期待した OP の `jwks_uri` から公開鍵を取得し、JWS（RS256）を検証する。`alg: none` は拒否する（JARM §2.4）
5. `aud` が自分の client_id と一致・`exp` が未来であることを確認する
6. クレームから `code` / `state` を取り出し、以降は通常の code フローと同じ

## 一次資料の読み方ガイド

- **JARM Final**（openid.net/specs/oauth-v2-jarm-final.html）: 短い仕様なので全文読了を推奨。読む順序は §2.1（クレーム構造と実例）→ §2.3.1 / §2.3.4（query.jwt と省略形 jwt）→ §4（AS メタデータ）→ §5（セキュリティ）。§2.2 の暗号化と §2.3.2 / §2.3.3 は本機能では非目標なので流し読みでよい。§2.4 は「クライアントが何を検証するか」であり、本 OP のテストコード（クライアント役）を書くときの必須要件になる
- **RFC 9700 §4.4**: mix-up 攻撃の脅威モデル。JARM がなぜ `iss` / `aud` を必須にするのかの背景
- **OAuth 2.0 Multiple Response Type Encoding Practices §2.1**: `response_mode` パラメータの原典。JARM 単体では response_mode の一般規則が書かれていないため、ここを先に読むと §2.3 が理解しやすい

## 昇格判断の観点

- 生成 OP の conformance テスト（JARM ケース）が 2 サイクル以上安定して通っているか
- auth transaction への拡張フィールド方式に対する不具合報告・store 実装の非互換報告が収束しているか（昇格時は core の `AuthTransaction` に正式フィールドとして追加する）
- FAPI 対応（PAR + JARM + PS256）を core の正式スコープにする方針判断が出ているか
- `form_post.jwt` / JWE / クライアント別 alg の要望が実際に来ているか（来ていなければ昇格後も非対応のままでよい）
