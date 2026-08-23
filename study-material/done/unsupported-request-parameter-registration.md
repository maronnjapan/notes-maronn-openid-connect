# `registration` リクエストパラメータの明示的拒否（`registration_not_supported`）

## 1. タイトル

OIDC Core §3.1.2.1 が定義する `registration` リクエストパラメータ（Self-Issued OP 向け）を本実装が非対応とする際に、§3.1.2.6 の `registration_not_supported` エラーで明示的に拒否すること。

## 2. このトピックで確認したいこと

- 認可リクエストに `registration` パラメータが含まれたとき、現状は**黙って無視**される。OIDC Core §3.1.2.6 は当該機能を非対応とする OP に `registration_not_supported` の返却を求めており、この差分を確認する
- 本トピックは `study-material/request-object-rejection-and-discovery-honesty.md`（`request` / `request_uri` → `request_not_supported` / `request_uri_not_supported`）と**同じ §3.1.2.6 の「未対応パラメータの明示的拒否」パターン**に属する。共通のエラー redirect 経路・Discovery 整合の考え方は重複説明せず、当該ファイルを参照する。本ファイルは `registration` パラメータ固有の差分のみを扱う
- `registration` は **Self-Issued OpenID Provider（OIDC Core §7）** が RP メタデータを認可リクエストに同梱するためのパラメータであり、通常の OP は受け取っても処理できない。よって「非対応であることを正しく返す」ことが Fidelity 上の論点となる

## 3. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md`「3.3」を参照。本トピック固有の要点:

- **OIDC Core 1.0 §3.1.2.1（Authentication Request）**: `registration` は OPTIONAL パラメータ。「This parameter SHOULD only be used when the Client Registration parameters need to be passed in the request itself, rather than registered with the OpenID Provider beforehand」。すなわち **Self-Issued OP（§7.2.1）** のユースケース向けに、RP のメタデータ（JSON）を認可リクエストに直接同梱するためのもの
- **OIDC Core 1.0 §3.1.2.6（Authentication Error Response）**: OP が `registration` パラメータをサポートしない場合、`registration_not_supported` エラーを返す。これは認可エラーとして（`state` を伴い）`redirect_uri` へ返すべきエラーに分類される（`request_not_supported` / `request_uri_not_supported` と同じ経路）
- **OIDC Core 1.0 §7.2.1**: Self-Issued OP における `registration` パラメータの本来の用途。通常の（Self-Issued ではない）OP はこの機能を持たないため、`registration_not_supported` を返すのが仕様準拠の挙動
- **Basic OP 認定との関係**: `registration` パラメータは Basic OP の必須テスト対象**ではない**（Self-Issued / Dynamic 系の範疇）。したがって「認定ブロッカー」ではなく、`request` / `request_uri` と同様に **仕様 Fidelity / 予測可能性 / パラメータ汚染の排除**の論点

## 4. 参照資料

- OpenID Connect Core 1.0 §3.1.2.1 — https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest （`registration` パラメータの定義と SHOULD only be used 条件）
- OpenID Connect Core 1.0 §3.1.2.6 — https://openid.net/specs/openid-connect-core-1_0.html#AuthError （`registration_not_supported` を含む認可エラー応答経路）
- OpenID Connect Core 1.0 §7（Self-Issued OpenID Provider） / §7.2.1 — https://openid.net/specs/openid-connect-core-1_0.html#SelfIssued （`registration` パラメータの本来のユースケース）
- 関連既存トピック: `study-material/request-object-rejection-and-discovery-honesty.md`（§3.1.2.6 の未対応パラメータ拒否パターン全般・エラー redirect 経路の共通議論）

## 5. 現在の実装確認

- `packages/core/src/authorization-request.ts`: `AuthorizationRequestParams`（行 32 付近）に `registration` フィールドが**存在しない**。`validateAuthorizationRequest` 本体でも `registration` を一切参照しておらず（grep で該当なし）、認可リクエストに含まれても**抽出も拒否もされず黙殺**される
- `AuthorizationErrorCode` enum（行 12-26）: `request_not_supported` / `request_uri_not_supported` / `registration_not_supported` の**いずれも未定義**。現状で §3.1.2.6 のうち実装済みなのは `interaction_required` / `login_required` / `account_selection_required` / `consent_required` のみ
- リダイレクト可能エラーの送出ポイントは確立済み（`authorization-request.ts` の「Phase 3 以降はリダイレクト可能エラー」区間、行 566 以降で `AuthorizationError(code, description, redirectUri, state)` を throw）。`registration` 検知の追加は、この区間に 1 分岐を足すだけで成立する

## 6. 現在の実装との差分

満たしていること:

- リダイレクト可能エラーの送出機構（`AuthorizationError` + redirect 経路）は既に存在し、`request` / `request_uri` の拒否を入れる際の経路（`study-material/request-object-rejection-and-discovery-honesty.md`）とまったく同じ場所に乗せられる

不足・確認が必要なこと:

- 🟡 **非対応エラー未返却**: `registration` を受けても `registration_not_supported` を返さない。OIDC Core §3.1.2.6 非準拠（Basic OP 必須ではないが Fidelity 軸に反する）
- 🟡 **`request` / `request_uri` と整合的に扱うべき**: 同じ §3.1.2.6 の 3 兄弟（`request_not_supported` / `request_uri_not_supported` / `registration_not_supported`）のうち、`registration` だけが別トピックの議論から漏れていた。3 つを同時に実装するか、段階導入するかの方針整合が必要
- 🟢 **Discovery 側の広告は不要**: `request_parameter_supported` 等と異なり、`registration` の非対応を示す Discovery メタデータフィールドは仕様に存在しない。よって Discovery 整合の論点は持たない（ここが request-object トピックとの差分）

## 7. 改善・追加を検討する理由

- 「最新の OIDC/OAuth 仕様を忠実に」を掲げる本 OSS にとって、§3.1.2.6 の MUST 級エラー挙動の欠落（3 兄弟のうち 1 つ）は Fidelity シグナルの毀損になる
- セキュリティ・予測可能性: `registration` を黙殺すると、攻撃者または誤用クライアントが RP メタデータ（`redirect_uris` 等）を `registration` で上書きしようと試みても OP が**それを無視して登録済みクライアント設定で処理**する。利用者が「動的に登録メタデータを差し込めた」と誤認するリスクを、明示拒否が排除する
- 導入容易性: `request` / `request_uri` 拒否（`study-material/request-object-rejection-and-discovery-honesty.md` の方針A）と**完全に同一の実装パターン**。3 兄弟をまとめて 1 つの「未対応パラメータ検知ブロック」として実装すれば、追加コストはほぼゼロ
- 拡張機能（`extension-dynamic-client-registration.md` / `ext-dynamic-client-registration.md`）との関係: 将来 Dynamic Client Registration（RFC 7591）を別途サポートしても、それは `registration_endpoint` 経由であり、認可リクエスト内 `registration` パラメータ（Self-Issued OP 向け）とは別物。よって「`registration` パラメータは恒久的に非対応で明示拒否」と確定しても DCR 拡張と矛盾しない
- 実装しない場合のリスク: 仕様非準拠の黙殺が残り、Self-Issued OP 互換を試した PoC 利用者が誤った成功体験を得る

## 8. 実装方針の候補

- 方針A（3 兄弟まとめて明示拒否, 推奨検討筆頭）:
  - `study-material/request-object-rejection-and-discovery-honesty.md` の `request` / `request_uri` 拒否と同時に、`registration` 検知 → `registration_not_supported` を 1 ブロックで実装
  - `AuthorizationErrorCode` に 3 つの enum 値を追加し、Phase 3 区間（redirect_uri 解決後）に「未対応パラメータ検知」分岐を 1 箇所追加
- 方針B（`registration` のみ単独実装）: request-object トピックと独立に進める。実装は同型だが、enum 追加と検知ブロックを別 PR で行う
- 方針C（現状維持・将来 Self-Issued OP 対応時に解禁）: `RELEASE-v0.x-scope.md` の「先端仕様は v0.x 非対象」方針に従い、当面は黙殺のまま。ただし Fidelity 軸の欠落は残る（非推奨）

最終方針は人間が判断。なお、本トピックと request-object トピックは「同じ検知ブロックで一括実装」するのが工数最小であるため、タスク化の際は**統合実装**を前提にすると効率がよい。

## 9. タスク案

- [ ] `request` / `request_uri` / `registration` の 3 兄弟を一括実装するか、`registration` を単独で進めるか方針決定
- [ ] `AuthorizationErrorCode` に `RegistrationNotSupported = 'registration_not_supported'`（および request 兄弟）を追加
- [ ] `authorization-request.test.ts`: `registration` 付与時に `registration_not_supported` の redirect error になることを先に追加（TDD）
- [ ] `authorization-request.ts` の Phase 3 区間（redirect_uri 解決後）に `registration` 検知・エラー化を実装
- [ ] `study-material/basic-op-requirement-traceability.md` の §6.5（Misc Request Params）に `registration` 行を追加し状態を更新
