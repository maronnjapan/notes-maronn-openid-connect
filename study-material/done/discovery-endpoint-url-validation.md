# Discovery メタデータのエンドポイント URL 検証（issuer 以外の https/絶対URL検証）

## 1. このトピックで確認したいこと

`buildProviderMetadata`（`packages/core/src/discovery.ts`）は `issuer` に対しては
`validateIssuer` で「有効な URL」「https スキーム（localhost 除く）」「クエリ無し」「フラグメント無し」
を検証している。一方で、Discovery で必須/推奨の **エンドポイント URL**
（`authorization_endpoint` / `token_endpoint` / `jwks_uri` / `userinfo_endpoint` /
`registration_endpoint` / `introspection_endpoint` / `revocation_endpoint`）は
**存在チェック（truthy 判定）しか行っておらず、URL としての妥当性・スキーム・フラグメント有無を検証していない**。

このトピックでは、OP が公開する Provider Metadata の各エンドポイント URL を、`issuer` と同等の
基準で検証すべきかどうか、その範囲と方針を整理する。

> 共通の仕様参照ハブは `study-material/basic-op-requirement-traceability.md` の「3. 関連する仕様・基準」を参照。
> Discovery のフィールド網羅・任意フィールドの扱いは `study-material/discovery-optional-metadata-fields.md`、
> issuer のマルチテナント/サブパスは `study-material/issuer-multitenancy-and-subpath.md` で既に扱っている。
> 本ファイルは「issuer 以外のエンドポイント URL の自己検証が欠落している」という差分のみを扱う。

## 2. 関連する仕様・基準（このトピック固有の差分）

- **OpenID Connect Discovery 1.0 §3 (OpenID Provider Metadata)**
  - `authorization_endpoint`: 「URL of the OP's OAuth 2.0 Authorization Endpoint」。REQUIRED。
  - `token_endpoint`: 「URL of the OP's OAuth 2.0 Token Endpoint」。Implicit のみの OP 以外は REQUIRED。
  - `jwks_uri`: 「URL of the OP's JSON Web Key Set document. ... This URL MUST use the `https` scheme」。REQUIRED。
  - `userinfo_endpoint`: 「URL of the OP's UserInfo Endpoint. ... This URL MUST use the `https` scheme and MAY contain port, path, and query parameter components」。RECOMMENDED。
  - §3 冒頭: 「Additional OpenID Provider Metadata parameters MAY also be used. ... values are URLs ... unless otherwise specified」。すなわちこれらは **絶対 URL** であることが前提。
- **RFC 8414 §2 (Authorization Server Metadata)**: `authorization_endpoint`, `token_endpoint`,
  `jwks_uri`, `introspection_endpoint`, `revocation_endpoint` を URL として定義。RFC 8414 §3.2 は
  「The `authorization_endpoint` and other endpoint URLs ... MUST be a URL」と規定。
- **`jwks_uri` の https 必須**は Discovery 1.0 で明示されており（上記）、`userinfo_endpoint` も https 必須。
  `authorization_endpoint` / `token_endpoint` は OIDC Core 1.0 §3.1.2.1 / §3.1.3.1 で TLS 必須
  （「Communication with the Authorization Endpoint MUST utilize TLS」「the Token Endpoint MUST utilize TLS」）。

ここで重要なのは、**仕様が規定するのは「OP が公開するメタデータの値が有効な https URL であること」**であり、
クライアントは不正なメタデータを拒否する。OP 側（本ライブラリ）が自身の設定値を検証することは
仕様上の MUST ではないが、`issuer` を既に検証している以上、**同等の防御を他エンドポイントにも
拡張するのが一貫している**（OSS 利用者の設定ミスを早期に検出できる）。

## 3. 参照資料

- OpenID Connect Discovery 1.0 — https://openid.net/specs/openid-connect-discovery-1_0.html
  - §3「OpenID Provider Metadata」: `authorization_endpoint` / `token_endpoint` / `jwks_uri`（https MUST）/ `userinfo_endpoint`（https MUST）の定義
- RFC 8414 OAuth 2.0 Authorization Server Metadata — https://datatracker.ietf.org/doc/html/rfc8414
  - §2 メタデータ定義、§3.2 検証要件
- OpenID Connect Core 1.0 incorporating errata set 2 — https://openid.net/specs/openid-connect-core-1_0.html
  - §3.1.2.1（Authorization Endpoint は TLS 必須）/ §3.1.3.1（Token Endpoint は TLS 必須）
- 既存の検証実装の根拠: `packages/core/src/discovery.ts` `validateIssuer`（issuer に対して同等の検証を実施済み）

## 4. 現在の実装確認

- ファイル: `packages/core/src/discovery.ts`
- `validateIssuer(issuer)`（117〜143行）: issuer に対し
  - `new URL()` で parse 可能か
  - `https`（または `localhost` / `127.0.0.1`）
  - `url.search`（クエリ）が無いこと
  - `url.hash`（フラグメント）が無いこと
  を検証している。
- `buildProviderMetadata(config)`（149行〜）:
  - `validateIssuer(config.issuer)` は呼ぶ（150行）。
  - `authorizationEndpoint` / `tokenEndpoint` / `jwksUri` は **truthy 判定のみ**
    （152〜160行: `if (!config.authorizationEndpoint) throw ...` 等）。
  - `userinfoEndpoint` / `registrationEndpoint` / `introspectionEndpoint` / `revocationEndpoint` は
    存在すればそのまま出力（196行以降）。**URL 妥当性・スキーム・フラグメントの検証は一切無い。**
- 結果として、例えば `tokenEndpoint: 'http://example.com/token'`（非 TLS）や
  `jwksUri: 'https://example.com/jwks#frag'`（フラグメント付き）、`authorizationEndpoint: 'not a url'`
  のような誤設定がそのまま Discovery ドキュメントに公開される。

## 5. 現在の実装との差分

- **満たしていること**
  - issuer は https/クエリ/フラグメントを検証済み。
  - 必須エンドポイント（authorization/token/jwks）の **存在** は検証済み。
- **不足している可能性があること**
  - 必須・推奨エンドポイント URL の **URL 妥当性**（`new URL()` で parse 可能か）が未検証。
  - `jwks_uri` / `userinfo_endpoint` の **https 必須**（Discovery 1.0 が明示する MUST）が未検証。
  - `authorization_endpoint` / `token_endpoint` の TLS（https）前提が未検証。
  - フラグメント付き URL（メタデータとして不適切）が素通りする。
- **相互運用性の観点**
  - 誤った（http や壊れた）エンドポイント URL を公開すると、Conformance Suite や本番クライアントが
    メタデータ取得段階で失敗する。OSS 利用者は原因がメタデータ設定にあると気づきにくい。
- **Basic OP として確認すべきこと**
  - Basic OP 認定そのものは Discovery を必須としないが、OIDF Conformance Suite の実行は Discovery 前提
    （→ `study-material/basic-op-conformance-verification-plan.md`）。公開メタデータが妥当な https URL で
    あることは、認定実行の前提条件として効いてくる。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: `issuer` だけ厳格に検証し、他エンドポイントは無検証という非対称は、
  「検証しているように見えて漏れる」典型。設定ミス（http のまま、コピペでフラグメント混入、URL タイポ）を
  ビルド時に早期検出でき、OSS 利用者の自己解決を助ける。
- **Basic OP 必須か拡張か**: 厳密には OP の自己検証は仕様 MUST ではない（拡張的な堅牢化）。ただし
  `jwks_uri` / `userinfo_endpoint` の https は Discovery 1.0 の MUST であり、それを満たさない値を
  公開しないためのガードとして妥当性が高い。位置づけは「堅牢化（防御的検証）」。
- **導入しやすさ**: 既に `validateIssuer` という同型の検証関数があるため、共通化したヘルパー
  （例 `validateEndpointUrl(name, url, { requireHttps })`）を切り出して各フィールドに適用するだけで済む。
  破壊的変更は「これまで素通りしていた誤設定が throw されるようになる」点のみで、正しい設定には影響しない。
- **接続先**: `buildProviderMetadata` 内で、各エンドポイント代入の直前に検証を挟む形。出力 `ProviderMetadata`
  の形は変えない。
- **メリット**: 利用者＝設定ミスの早期検知。運用者＝公開メタデータの妥当性保証。開発者＝issuer との一貫性。
- **実装しない場合のリスク**: 非 TLS / 壊れた URL を公開し、クライアント側でのみ失敗 → デバッグ困難。
  localhost 開発から本番昇格時に http のまま残る事故を検出できない。

## 7. 実装方針の候補（人間が最終判断）

- **方針 A（推奨度: 高）**: 共通ヘルパー `validateEndpointUrl(fieldName, value, options)` を新設し、
  `validateIssuer` のロジック（parse 可能 / https（localhost 例外）/ フラグメント無し）を再利用。
  - `jwks_uri` / `userinfo_endpoint`: https 必須（localhost のみ例外）、フラグメント不可。
  - `authorization_endpoint` / `token_endpoint`: https 必須（localhost 例外）、フラグメント不可、クエリは許容
    （仕様上クエリ付き URL は許される。issuer と異なりクエリ禁止にはしない点に注意）。
  - `registration_endpoint` / `introspection_endpoint` / `revocation_endpoint`: 同様に https 必須。
  - 検証失敗時は既存スタイルに合わせて `throw new Error('<field> must use https scheme ...')`。
- **方針 B（最小）**: `new URL()` で parse 可能かのみ検証（スキームは検証しない）。誤った文字列・相対 URL を
  弾くが、http 公開は許してしまう。Discovery 1.0 の https MUST を満たせないため非推奨。
- **方針 C（厳格）**: localhost 例外を設けず常に https 必須。開発体験（localhost サンプル）を損なうため、
  本リポジトリの既存 `validateIssuer` の localhost 例外方針と矛盾する。非推奨。

注意点（判断材料）:
- issuer は「クエリ禁止」だが、`authorization_endpoint` / `userinfo_endpoint` などは **クエリ許容**。
  検証ヘルパーは `forbidQuery` をフィールドごとに切り替えられる設計にする必要がある（issuer と同じ関数を
  そのまま流用しない）。
- 既存テスト（`discovery.test.ts`）が「http エンドポイントでも metadata を組み立てられる」前提で書かれて
  いないか要確認。書かれている場合は localhost に置換するか https に修正する。

## 8. タスク案

- [ ] `validateIssuer` を一般化した `validateEndpointUrl(fieldName, url, { requireHttps, forbidQuery, forbidFragment })`
  を `discovery.ts` に追加（issuer は `forbidQuery: true`、他エンドポイントは `forbidQuery: false`）。
- [ ] `buildProviderMetadata` で `authorization_endpoint` / `token_endpoint` / `jwks_uri` /
  `userinfo_endpoint` / `registration_endpoint` / `introspection_endpoint` / `revocation_endpoint` を検証。
- [ ] `discovery.test.ts` にテスト追加: 非 https の token/jwks/userinfo を拒否、フラグメント付きを拒否、
  クエリ付き authorization_endpoint は許容、localhost は許容、壊れた URL を拒否。
- [ ] 既存テスト・サンプル設定に http エンドポイントが無いか確認し、必要なら localhost / https へ修正。
- [ ] CLI 生成物（samples/*）の設定が https または localhost であることを確認（`packages/cli` 側の
  デフォルト config テンプレートが http を吐かないこと）。
