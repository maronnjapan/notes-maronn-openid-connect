# pairwise な sub のメモ

pairwise な `sub` の作り方と、DCR および Discovery のメタデータとの関係を、仕様の原文で確かめた結果を残す。
参照した仕様は OpenID Connect Core 1.0、Discovery 1.0、Dynamic Client Registration 1.0 で、いずれも errata set 2 の版である（2026-10-24 確認）。
実装方針の比較やタスク案は `study-material/pairwise-subject-identifier.md` にある。

## sub の算出方法

pairwise な `sub` は、Sector Identifier、OP 内のユーザー ID、OP だけが知る salt を連結し、ハッシュ化または暗号化すれば作れる。
Core §8.1 は次の三つの方式を例に挙げている。

- **ハッシュ**：`sub = SHA-256(sector_identifier || local_account_id || salt)`
- **暗号化**：`sub = AES-128(sector_identifier || local_account_id || salt)`
- **対応表**：Sector Identifier とユーザー ID の組ごとに GUID を発行し、保存する

方式は自由に選べるが、どの方式も次の性質を満たさなければならない（MUST）。

- OP 以外が `sub` から元の値を逆算できない
- Sector Identifier が異なれば、`sub` も異なる
- 同じ入力からは常に同じ `sub` が出る（決定的である）

入力に使うのは URL 全体ではなく、URL のホスト部である **Sector Identifier** である。
`sector_identifier_uri` を登録したクライアントではそのホスト部を、登録していないクライアントでは `redirect_uri` のホスト部を使う。
パスは入力に入らないので、`https://rp.example.com/a/cb` と `https://rp.example.com/b/cb` は同じ Sector Identifier になる。

`sub` を分ける単位も、クライアントではなく Sector Identifier である。
§8 は pairwise を「クライアントごとに異なる `sub`」と定義しているが、§8.1 は Sector Identifier ごとに一意な `sub` を算出するよう求めている（MUST）。
例示された三つの方式はどれも `client_id` を入力に含まない。
そのため、同じ Sector Identifier を持つクライアント同士（たとえば、`sector_identifier_uri` を登録せずに同じホストへ `redirect_uri` を置くクライアント同士）は、同じ `sub` を受け取る。

実装では、次の点に気を付ける。

- **salt の秘匿**：ハッシュ方式で salt が漏れると、ユーザー ID が連番やメールアドレスのように推測しやすい値であれば、候補を総当たりして `sub` からユーザーを特定できる。Sector Identifier をまたいだ名寄せもできてしまう。
- **暗号化の決定性**：暗号化方式では、同じ入力から同じ出力が出る方式（AES-SIV など）を選ぶ。呼び出しごとにランダムな IV や nonce を使う方式では、ログインのたびに `sub` が変わる。Web Crypto API には AES-SIV がないので、Web 標準 API だけで作るなら、salt を鍵にした HMAC-SHA-256 などのハッシュ方式が扱いやすい。
- **連結の境界**：区切り文字か長さの接頭辞で、要素の境界を固定する。境界がないと、`a.example` と `b123` を連結した文字列と、`a.exampleb` と `123` を連結した文字列が一致する。
- **文字列への変換**：ハッシュ値や暗号文はバイト列なので、base64url などで文字列にする。`sub` は 255 ASCII 文字を超えてはならない（Core §2）。
- **逆引き**：セッションのない場面で、受け取った `sub` からユーザーを特定する処理（CIBA の `id_token_hint` など）があると、ハッシュ方式だけではユーザーを引けない。対応表を併用するか、OP が復号できる暗号化方式を選ぶ。

## DCR で pairwise に対応するときの sector_identifier_uri

DCR では、クライアントが登録リクエストで `sector_identifier_uri` を送れる（Registration §2、OPTIONAL）。
値は https の URL で、`redirect_uri` の値を並べた JSON 配列のファイルを指さなければならない（MUST）。
ファイルは RP 側が公開し、OP が登録時に取得する。

```json
{
  "redirect_uris": ["https://client.example.org/callback"],
  "subject_type": "pairwise",
  "sector_identifier_uri": "https://other.example.net/file_of_redirect_uris.json"
}
```

この `sector_identifier_uri` は、次の配列を返す。

```json
[
  "https://client.example.org/callback",
  "https://client.example.org/callback2",
  "https://client.other_company.example.net/callback"
]
```

OP は登録時に、このファイルを使って `redirect_uris` を検証する（Registration §5）。

- 登録する `redirect_uris` がすべて配列に含まれていなければ、登録を失敗させる（MUST）。
- 検証は登録時に行う（MUST）。ファイルの内容を保持する義務も、後から取得し直して再検証する義務もない。
- 失敗時のエラーコードは指定されていない。Registration §3.3 の `invalid_redirect_uri` か `invalid_client_metadata` が候補になる。

ただし、pairwise に対応する DCR でも、`sector_identifier_uri` が常に必須というわけではない。
登録する `redirect_uris` のホストが一つなら、そのホストが Sector Identifier になる。
ホストが複数ある場合は、クライアントが `sector_identifier_uri` を登録しなければならない（Core §8.1、MUST）。
pairwise を使い DCR に対応する OP は、`sector_identifier_uri` を使うべきとされている（Core §8.1、SHOULD）。

`sector_identifier_uri` を登録すると、Sector Identifier は `redirect_uris` のホストではなく、`sector_identifier_uri` 自身のホスト（例では `other.example.net`）になる。
そのため、同じ組織が管理する複数ドメインのサイトへ同じ `sub` を返せる。
`redirect_uri` のドメインを移しても、`sector_identifier_uri` のホストが変わらなければ `sub` は変わらない。

OP はクライアントが指定した URL を取得するので、SSRF への対策が要る。

## subject_types_supported と subject_type の関係

二つの値は、持ち主が異なるメタデータである。

- **`subject_types_supported`**：OP のメタデータ。OP が対応する種別（`public`、`pairwise`）を Discovery に並べる（Discovery §3 で REQUIRED、Core §8 でも MUST）。
- **`subject_type`**：クライアントのメタデータ。クライアントが使いたい種別を一つ、DCR の登録リクエストで伝える（Registration §2、OPTIONAL）。

DCR を使うクライアントは、OP の `subject_types_supported` に並ぶ種別から `subject_type` を選ぶ。
Core §8 は、二つ以上の種別が並んでいれば、クライアントが登録時に `subject_type` で希望を伝えてよい（MAY）としている。
DCR を使わない静的登録では、クライアントごとの種別を OP 側の設定で決める。
仕様はその設定方法を定めていない。

どちらの登録方法でも、Discovery を提供する OP は `subject_types_supported` を載せる。
DCR は、その中からクライアント自身が種別を選ぶ手段を加えるだけである。

DCR で要求された種別の扱いは、Registration の一般規定に従う。

- Registration §3.2 は、`redirect_uris` 以外の要求値を OP が拒否または置換してよい（MAY）とし、置換した値は応答に含めなければならない（MUST）としている。対応していない `subject_type` が来た場合も、この規定に従って拒否するか置換する。
- `subject_type` を省略した場合の既定値は Registration に定めがなく、OP の方針で決める。

## OSS 実装の現状

2026-10-24 時点の OSS 実装リポジトリ（main、`a5e4f70`）を確認した。

- Discovery は `subject_types_supported: ["public"]` だけを広告している（`apps/hono/src/oidc-provider/endpoints/discovery/steps/build-metadata.ts`、`apps/nextjs/src/app/.well-known/openid-configuration/route.ts`）。
- pairwise な `sub` を算出する処理はない。
- experimental の DCR は、`subject_type` と `sector_identifier_uri` を未知フィールドとして捨てる（`packages/experimental/src/dynamic-client-registration/registration-request.ts`）。URL を取得する処理が SSRF の面を開くため、受理しないと決めている（`tasks/experimental/done/dynamic-client-registration/specification.md` の非目標）。

## 参照

- OpenID Connect Core 1.0 §8：https://openid.net/specs/openid-connect-core-1_0.html#SubjectIDTypes
- OpenID Connect Core 1.0 §8.1：https://openid.net/specs/openid-connect-core-1_0.html#PairwiseAlg
- OpenID Connect Discovery 1.0 §3：https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata
- OpenID Connect Dynamic Client Registration 1.0 §2：https://openid.net/specs/openid-connect-registration-1_0.html#ClientMetadata
- OpenID Connect Dynamic Client Registration 1.0 §3.2：https://openid.net/specs/openid-connect-registration-1_0.html#RegistrationResponse
- OpenID Connect Dynamic Client Registration 1.0 §3.3：https://openid.net/specs/openid-connect-registration-1_0.html#RegistrationError
- OpenID Connect Dynamic Client Registration 1.0 §5：https://openid.net/specs/openid-connect-registration-1_0.html#SectorIdentifierValidation
