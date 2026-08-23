# Discovery の `token_endpoint_auth_methods_supported` を省略すると実サポート方式を過少広告する（RFC 8414 §2 の既定値との齟齬）

## ステータス

🟢 Low / 未着手

## 1. このトピックで確認したいこと

`buildProviderMetadata` は `tokenEndpointAuthMethodsSupported` が未設定だと、Discovery 文書から
`token_endpoint_auth_methods_supported` を**省略**する。ところが RFC 8414 §2 / OIDC Discovery §3 では、
このフィールドを省略した場合の**既定値は `client_secret_basic` のみ**と定義される。実装の Token Endpoint
（`client-auth.ts`）は `client_secret_basic` / `client_secret_post` / `none` の 3 方式を受け付けるため、
省略すると「実際にサポートしている方式を過少に広告する」ことになる。`client_secret_post` や `none` で
登録されたクライアントは、Discovery からその方式が使えることを知る手段が無い。

本ファイルは、Discovery が広告する認証方式と OP の実サポートを一致させる（advertised == actual）方針を検討する。

> 関連既存ファイル（重複回避）：
> - `study-material/discovery-optional-metadata-fields.md`: Discovery の任意メタデータ**追加**の全般を扱う。
>   本ファイルは **`token_endpoint_auth_methods_supported` の省略が RFC 8414 既定値により実サポートを過少広告する**
>   という具体的な齟齬に絞る。
> - `study-material/done/client-metadata-enforcement.md` / `tasks/done/p0-client-authentication.md`:
>   クライアント認証方式の**強制**を扱うが、Discovery での**広告**の齟齬は対象外。
> 本ファイル固有の論点は「**Discovery の認証方式広告を OP の実サポート（3 方式）に一致させる**」こと。

## 2. 関連する仕様・基準

- **RFC 8414 §2（Authorization Server Metadata, `token_endpoint_auth_methods_supported`）**:
  > OPTIONAL. ... If omitted, the default is "client_secret_basic".
  - 省略＝「`client_secret_basic` のみサポート」と解釈される。
- **OpenID Connect Discovery 1.0 §3（同フィールド）**: 同上の既定値。
- **本 OP の実サポート（`client-auth.ts`）**: `client_secret_basic` / `client_secret_post` / `none` を受理。
  したがって省略すると `client_secret_post` / `none` が「広告されていないが実際は使える」状態になり、
  advertised と actual が食い違う。
- **相互運用性の原則**: メタデータは「クライアントが正しく振る舞うための宣言」であり、
  実サポートより狭く広告すると、動的にメタデータを見て方式を選ぶクライアントが正しい方式を選べない。

## 3. 参照資料

- RFC 8414 §2（`token_endpoint_auth_methods_supported`, 既定値）: https://www.rfc-editor.org/rfc/rfc8414#section-2
- OpenID Connect Discovery 1.0 §3: https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata
- OpenID Connect Core 1.0 §9（Client Authentication）: https://openid.net/specs/openid-connect-core-1_0.html#ClientAuthentication

## 4. 現在の実装確認

- `packages/core/src/discovery.ts`
  - `buildProviderMetadata`（`:221-223` 付近）:
    `config.tokenEndpointAuthMethodsSupported` が非空のときだけ `token_endpoint_auth_methods_supported` を出力。
    未設定なら省略 → RFC 8414 の既定 `client_secret_basic` のみと解釈される。
- `packages/core/src/client-auth.ts`
  - Token Endpoint のクライアント認証は `client_secret_basic` / `client_secret_post` / `none` の 3 方式を受理
    （既定は `client_secret_basic`, `:159` 付近）。
- CLI 生成テンプレートが `tokenEndpointAuthMethodsSupported` を明示設定しているかは要確認
  （設定していれば実害は無いが、既定に頼っている経路があると過少広告になる）。

## 5. 現在の実装との差分

- **満たしていること**
  - `tokenEndpointAuthMethodsSupported` を明示設定すれば正しく広告される（機構は存在）。
- **不足している可能性があること**
  - 未設定時に「実サポート 3 方式」ではなく「既定 `client_secret_basic` のみ」に縮む。
    CLI テンプレートが明示設定していない場合、生成 OP の Discovery が実サポートを過少広告する。
- **相互運用性の観点**
  - `client_secret_post` / `none` で登録したクライアントが、Discovery からその方式の利用可否を判断できない。
- **Basic OP として確認すべきこと**
  - Discovery の認証方式広告は、advertised == actual であることが望ましい（Fidelity）。

## 6. 改善・追加を検討する理由

- **Fidelity / 相互運用性**: 「広告した方式 == 実際に使える方式」を保つことは、メタデータ駆動のクライアント連携で重要。
- **導入しやすさ**: CLI 生成テンプレートで `tokenEndpointAuthMethodsSupported` を実サポート（3 方式）に明示設定するだけ。
  あるいは core 側で「未設定時のデフォルトを実サポートに合わせる」ことも検討可能（ただし core は
  実際に受理する方式を知らないため、生成テンプレート側で明示する方が素直）。
- **実装しない場合のリスク**: 動的メタデータを信頼するクライアントが `client_secret_post`/`none` を使えないと誤認する。
- 優先度は低い（Low）。多くのクライアントは登録時の合意で方式を決めるため実害は限定的だが、
  メタデータ忠実性の観点で是正しておく価値がある。

## 7. 実装方針の候補

判断材料の整理（最終判断は人間）。

- 方針A（推奨）: CLI 生成テンプレートで `tokenEndpointAuthMethodsSupported: ['client_secret_basic',
  'client_secret_post', 'none']`（実サポートに一致）を明示設定する。
  - Discovery が実サポートを正しく広告する。core 変更不要。
- 方針B: core の `buildProviderMetadata` に「実サポート方式のヒント」を渡す仕組みを足し、未設定時に補完。
  - 汎用的だが、core が「どの方式を受理するか」を知る必要があり、責務が広がる。方針A の方が軽い。
- どちらでも、`none`（public client）を広告する場合は PKCE 必須などの前提が崩れないことを確認する。

## 8. タスク案

- [ ] CLI 生成テンプレート（各フレームワーク）が `tokenEndpointAuthMethodsSupported` を明示設定しているか横断確認
- [ ] `discovery.test.ts` に「実サポート 3 方式が `token_endpoint_auth_methods_supported` に載る」テストを追加
- [ ] 方針A で生成テンプレートに実サポート方式を明示設定
- [ ] 各 sample の Discovery 出力（conformance.test.ts）で広告方式が実サポートと一致することを固定
- [ ] 完了条件: `pnpm test`（core + 該当 sample）がパス
