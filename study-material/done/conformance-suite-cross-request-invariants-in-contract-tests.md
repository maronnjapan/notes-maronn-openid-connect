# Conformance Suite が検証する「クロスリクエスト不変条件」が契約テストに落ちていない

## 1. このトピックで確認したいこと

本リポジトリの自動テストは、大きく 2 層ある。

- `packages/*/src/*.test.ts`: 関数単位のユニットテスト
- `samples/*/src/oidc-provider/conformance.test.ts`: 生成 OP を `app.request()` で駆動する契約テスト

一方、Basic OP 認定の判定は OIDF Conformance Suite が行う。Suite は Docker + 外部ネットワーク +
一部 module の手動 screenshot 提出を要するため（📌 `tests/conformance/README.md`）、
**CI で常時回せない**。したがって「Suite を回すまで気づけない退行」が構造的に残る。

ここで問題になるのは、Suite のアサーションのうち **1 リクエスト内では判定できない
「クロスリクエスト不変条件」** である。例えば「refresh 後の ID Token の `iat` は初回と異なること」は、
初回レスポンスと refresh レスポンスの**両方を持っていないと検証できない**。
現在の契約テストはフローを通しているのでこの 2 つを持っているが、**比較していない**。

このファイルで確認したいのは次の 3 点。

1. Suite が実際に実行するクロスリクエスト条件が何か（一次情報＝Suite ソースから確定させる）
2. そのうち、現在の契約テストが検証していないものはどれか
3. それを契約テストへ翻訳する価値と、翻訳できない（Suite でしか判定できない）ものの切り分け

> **重複回避の方針**:
> - Suite の**実行手順・環境構築**は 📌 `study-material/basic-op-conformance-verification-plan.md` と
>   📌 `tests/conformance/README.md` が扱う。本ファイルは実行手順を繰り返さない。
> - **仕様要件→実装のトレーサビリティ**は 📌 `study-material/basic-op-requirement-traceability.md` が扱う。
>   本ファイルは「仕様要件」ではなく「**Suite の判定ロジック**」を対象にする（両者は一致しない部分がある）。
> - **CLI 生成物を CI で検証する**話は 📌 `study-material/done/cli-generated-output-conformance-ci.md` /
>   📌 `tasks/done/p2-cli-generated-output-verification-ci.md` が扱う。本ファイルは
>   「何をアサートするか」に絞り、CI 配線の話は繰り返さない。
> - 本ファイルが具体例として挙げる `iat` / トークン一意性の**問題そのもの**は
>   📌 `study-material/done/token-value-uniqueness-same-second-jwt-reissuance-collision.md` が扱う。
>   本ファイルの差分は「**なぜそれをテストが検出できなかったのか**」という構造の話。

## 2. 関連する仕様・基準

- **OpenID Connect Conformance Profiles / Basic OP**: 認定は「プロファイル内の全 module が
  PASSED / REVIEW / WARNING / SKIPPED であること」で判定され、FAILED / INTERRUPTED が 1 つでも
  あると認定できない（OIDF の OP テスト手引き）。すなわち **Suite の判定ロジックが事実上の合否基準**であり、
  仕様条文の読み方と Suite の実装が食い違う場合、認定上は Suite の実装が優先される。
- **OIDC Core 1.0 §12.2 (Successful Refresh Response)**: refresh で返す ID Token について
  `iss` / `sub` は同一、`aud` は同一、`iat` は新しい発行時刻を表す、`auth_time` は初回認証時刻、
  `azp` は初回と同一、といった不変条件を定める。**これらは 1 レスポンス単体では検証できない。**
- **RFC 6749 Appendix A.17 (`refresh-token` syntax)**: リフレッシュトークンは `1*VSCHAR`。
  Suite はこれを文字種チェックとして実装している。
- **RFC 9700 §4.14 / OAuth 2.1 §4.3.1**: rotation。Suite はクライアント跨ぎのバインディング
  （client 2 の refresh token を client 1 で使えないこと）を明示的に検証する。

## 3. 参照資料

一次情報は OIDF Conformance Suite のソース（master ブランチ、本調査時点）。

- Basic OP のテストプラン構成（module 一覧）—
  https://gitlab.com/openid/conformance-suite/-/raw/master/src/main/java/net/openid/conformance/openid/OIDCCBasicTestPlan.java
  含まれる module（本調査時点で確認できたもの）:
  `OIDCCServerTest`, `OIDCCResponseTypeMissing`, `OIDCCIdTokenSignature`, `OIDCCIdTokenUnsigned`,
  `OIDCCUserInfoGet`, `OIDCCUserInfoPostHeader`, `OIDCCUserInfoPostBody`,
  `OIDCCEnsureRequestWithoutNonceSucceedsForCodeFlow`, `OIDCCScopeProfile`, `OIDCCScopeEmail`,
  `OIDCCScopeAddress`, `OIDCCScopePhone`, `OIDCCScopeAll`, `OIDCCAlternateHappyFlow`,
  `OIDCCDisplayPage`, `OIDCCDisplayPopup`, `OIDCCPromptLogin`, `OIDCCPromptNoneNotLoggedIn`,
  `OIDCCPromptNoneLoggedIn`, `OIDCCMaxAge1`, `OIDCCMaxAge10000`,
  `OIDCCEnsureRequestWithUnknownParameterSucceeds`, `OIDCCIdTokenHint`, `OIDCCLoginHint`,
  `OIDCCUiLocales`, `OIDCCClaimsLocales`, `OIDCCEnsureRequestWithAcrValuesSucceeds`,
  `OIDCCAuthCodeReuse`, `OIDCCAuthCodeReuseAfter30Seconds`, `OIDCCEnsureRegisteredRedirectUri`,
  `OIDCCEnsurePostRequestSucceeds`, `OIDCCServerTestClientSecretPost`,
  `OIDCCRequestUriUnsignedSupportedCorrectlyOrRejectedAsUnsupported`,
  `OIDCCUnsignedRequestObjectSupportedCorrectlyOrRejectedAsUnsupported`, `OIDCCClaimsEssential`,
  `OIDCCEnsureRequestObjectWithRedirectUri`, `OIDCCRefreshToken`,
  `OIDCCEnsureRequestWithValidPkceSucceeds`
  - ⚠️ **未確定**: 実際に本リポジトリが回している
    `oidcc-basic-certification-test-plan[server_metadata=discovery][client_registration=static_client]`
    は 35 module と記録されている（📌 `tasks/done/p1-basic-op-static-client-conformance-result-2026-06-21.md`）。
    上記一覧は 38 件で、件数が一致しない。certification plan は variant による絞り込みを伴うため
    差分が出るものと考えられるが、**certification plan 側のソースは本調査で取得できなかった**。
    件数と対応関係の確定は要追加調査（タスク案を参照）。
- `OIDCCRefreshToken` module —
  https://gitlab.com/openid/conformance-suite/-/raw/master/src/main/java/net/openid/conformance/openid/OIDCCRefreshToken.java
  - OP がリフレッシュトークンを発行しない場合は skip される
  - `offline_access` 付きで認可 → token → refresh
  - `EnsureRefreshTokenContainsAllowedCharactersOnly`（RFC 6749 Appendix A.17）
  - **client 2 のリフレッシュトークンを client 1 で使うとエラーになること**（クライアントバインディング）
- `RefreshTokenRequestSteps`（refresh 応答に対して実行される条件列）—
  https://gitlab.com/openid/conformance-suite/-/raw/master/src/main/java/net/openid/conformance/sequence/client/RefreshTokenRequestSteps.java
  - HTTP 200 / JSON content type / キャッシュヘッダ
  - アクセストークン: 抽出・`token_type`・**最小エントロピー**・許可文字種・`expires_in`・
    **直前のトークンと異なること（uniqueness）**
  - リフレッシュトークン: 抽出・**最小長**・**最小エントロピー**
  - ID Token: 抽出・暗号化検証・`CompareIdTokenClaims`（2 つ目の ID Token がある場合）
- `CompareIdTokenClaims` —
  https://gitlab.com/openid/conformance-suite/-/raw/master/src/main/java/net/openid/conformance/condition/client/CompareIdTokenClaims.java
  - `iss` / `sub` 一致、`aud` 一致（配列は集合比較）
  - **初回に `azp` が無ければ再発行にも `azp` があってはならない**、あれば一致
  - 再発行に `auth_time` があれば初回と一致
  - **`iat` が初回と同値ならエラー**
  - `nonce` は検証対象外
- 本リポジトリ内: `samples/*/src/oidc-provider/conformance.test.ts`（契約テスト。生成元は
  `packages/cli/src/frameworks/hono/templates.ts` の `reuseFlowConformanceTestBlock` 等）、
  `tests/conformance/README.md`（Suite 実行手順と実測記録）

## 4. 現在の実装確認

### 4-1. 契約テストは「フローが通ること」を見て「不変条件」を見ていない

`samples/hono-cloudflare/src/oidc-provider/conformance.test.ts` の
`Authorization Code & Refresh Token reuse (revoke-cascade contract)` にある
`should reject rotated refresh token reuse and revoke every token from that grant`
（該当箇所は L1209 付近）は、次を検証している。

- authorize → login → consent → code 取得（各ステップの status）
- `grant_type=authorization_code` が 200
- `grant_type=refresh_token` が 200 で、新しい access / refresh token が返る
- rotation 済み refresh token の再利用が `invalid_grant`
- カスケード失効（rotation 後の access が 401、rotation 後の refresh が `invalid_grant`）

**検証していないもの**（＝Suite が検証するもの）:

- rotation 後の `access_token` が初回と**異なる値**であること
- rotation 後の `id_token` の `iat` が初回と**異なる**こと
- rotation 後の `id_token` の `iss` / `sub` / `aud` / `auth_time` が初回と**一致**すること
- 初回に `azp` が無いなら rotation 後にも `azp` が無いこと
- トークン値の最小長・最小エントロピー・許可文字種

### 4-2. その結果、実在する不具合を検出できていない

📌 `study-material/done/token-value-uniqueness-same-second-jwt-reissuance-collision.md` に記録したとおり、
上記テストを一時計測したところ、**rotation 後の `access_token` と `id_token` は初回とバイト単位で同一**
だった（in-process のため同一秒に収まる）。契約テストは値の一意性をアサートしていないので、
この状態でグリーンのままである。

つまり、Suite のアサーション 1 行（uniqueness）が契約テストに無いことが、実在する退行を
見逃す原因になっている。これは偶然ではなく**構造的な穴**である。

### 4-3. Suite でしか判定できないもの

一方で、契約テストに翻訳しても意味が薄い／翻訳できないものもある。

- ブラウザ操作を伴う module（`OIDCCPromptLogin` / `OIDCCMaxAge1` の 2 回目ログイン画面、
  `OIDCCEnsureRegisteredRedirectUri` の error page）→ **screenshot による manual review** が前提。
  E2E（Playwright）の領域であり、契約テストの範囲外。
- Discovery と実挙動の突き合わせ全般 → 一部は既に
  📌 `tasks/p3-discovery-metadata-basic-op-self-consistency-guard.md` などで扱っている。

## 5. 現在の実装との差分

### 満たしていること

- Basic OP の主要フローは契約テストで HTTP レベルまで固定されている（112 の `it`）
- Suite の実行手順・実測結果・manual review 手順は文書化済み（`tests/conformance/README.md`）
- 生成物の再生成と契約テストの同期は CLI テンプレート側で担保する運用が確立している（CLAUDE.md の方針）

### 不足している可能性があること

- 🟠 **クロスリクエスト不変条件のアサートが 0 件**: 4-1 のとおり、refresh 前後の ID Token 比較・
  トークン値の一意性は 1 つも検証されていない。Suite の `CompareIdTokenClaims` に相当する
  アサーションが契約テストに存在しない。
- 🟡 **トークン値の形式的性質（長さ・エントロピー・文字種）が未検証**: Suite は明示的に検査する。
  本リポジトリは `generateRandomString(32)` を使っており実態としては満たしているが、
  **利用者が `AccessTokenIssuer` を差し替えたときに壊れても検出されない**。
  独自 issuer は本ライブラリの主要な拡張ポイントであり、ここが無検査なのは拡張性の観点で弱い。
- 🟡 **Suite の module 一覧と契約テストの対応表が無い**: どの module が契約テストで先取りされ、
  どれが Suite / E2E / manual review 専任なのかが一覧化されていない。
  そのため「新しい機能を足したとき、どのテスト層に何を書けばよいか」の判断が属人的になる。
- 🟡 **certification plan の module 一覧が未確定**: 3 節のとおり 38 件 vs 35 件の差分が未解決。
  「Basic OP として何を満たすべきか」の全集合が確定していないのは、Fidelity を掲げる以上は弱い。

### Basic OP として提供する上で確認すべきこと

- 認定の合否は Suite の判定ロジックで決まる。仕様条文だけを根拠にテストを書くと、
  Suite が追加で見ている条件（uniqueness / entropy / `azp` の非存在一致）を取りこぼす。
  **一次情報として Suite ソースも参照する**運用が必要かどうかが判断ポイント。

## 6. 改善・追加を検討する理由

- **なぜ検討すべきか**: 本リポジトリの差別化軸は Speed / Fidelity / Portability であり、
  Fidelity は「Conformance 準拠を信頼性のシグナルとして維持する」と定義されている
  （CLAUDE.md）。Suite を常時回せない以上、**Suite のアサーションを CI で回せる形に写す**ことが
  そのシグナルを維持する現実的な手段になる。
- **Basic OP 必須か拡張か**: テスト戦略そのものは仕様要件ではない。ただし
  「Basic OP を満たし続けている」と主張するための**根拠の質**に直結する。
- **導入しやすさ**: 対象は既存の契約テスト 1 ファイル（生成元は `packages/cli` のテンプレート）で、
  追加するのは既に取得済みのレスポンス同士を比較する数行。新しいインフラは不要。
  4-2 で「今書けば Red になる」ことまで確認済みなので、TDD の Red → Green がそのまま成立する。
- **導入しにくさ**: 契約テストは 4 フレームワーク分が生成物であるため、テンプレート側を直して
  全 sample を再生成する必要がある（CLAUDE.md の必須ルール）。差分レビューの範囲は広くなる。
- **利用者のメリット**: 生成コードを改造した利用者が、`conformance.test.ts` を回すだけで
  「Basic OP の想定挙動から外れた」ことを検知できる範囲が広がる。これは
  `conformance.test.ts` を契約テストとして扱う既存方針そのものの強化になる。
- **実装しない場合に残るリスク**: Suite を回す頻度（実質、認定時と大きな変更時のみ）に
  検知が依存し続ける。認定取得後に入った退行が、次回認定まで気づかれない。

## 7. 実装方針の候補（最終判断は人間が行う）

### 方針A: 「Suite 由来アサーション」を契約テストに追加する（最小・即効）

- `reuseFlowConformanceTestBlock`（`packages/cli/src/frameworks/hono/templates.ts`）に、
  refresh 前後の比較アサーションを追加する。
  - `expect(rotatedAccess).not.toBe(firstAccess)`
  - `expect(idTokenPayload(rotatedId).iat).not.toBe(idTokenPayload(firstId).iat)`
  - `iss` / `sub` / `aud` / `auth_time` の一致、`azp` の非存在一致
- 利点: 小さく、今すぐ Red が取れる。既存の契約テスト方針と完全に整合。
- 論点: 実装を直さないと Red のままになるため、
  📌 `study-material/done/token-value-uniqueness-same-second-jwt-reissuance-collision.md` の修正と
  順序を揃える必要がある（テストだけ先に入れると CI が赤になる）。

### 方針B: トークン値の形式的性質を core のユニットテストで固定する

- `generateRandomString` / `createOpaqueAccessTokenIssuer` に対し、長さ・文字種
  （base64url = `[A-Za-z0-9\-_]`, RFC 6749 Appendix A.17 の VSCHAR を満たす）を固定するテストを置く。
- `AccessTokenIssuer` の契約テストヘルパー（利用者が独自 issuer を検証できるもの）を公開するかは別判断。
- 利点: 拡張ポイントを差し替える利用者への安全網になる。
- 論点: エントロピーの「測定」はテストで厳密にはできない。長さ・文字種・複数回発行の相異までが現実的。

### 方針C: Suite module ↔ テスト層の対応表を作る

- `study-material/basic-op-requirement-traceability.md` に列を足すか、
  `tests/conformance/README.md` に表を足す。
- 各 module について「契約テストで先取り済み / E2E 担当 / Suite 専任（manual review）」を明示する。
- 利点: 新機能追加時に「どこにテストを書くか」が機械的に決まる。
- 論点: 維持コスト。Suite のバージョンアップで module が増減するため、更新運用が要る。

### 方針D: 何もしない（Suite 実行の頻度を上げる運用でカバー）

- 論点: 3 節・`tests/conformance/README.md` のとおり、Suite 実行は Docker / 外部ネットワーク /
  手動 screenshot を要し、restricted-network 環境では迂回手順が必要だった。
  「頻度を上げる」が現実的かどうかを先に評価する必要がある。

### 判断の分岐点（人間が決めること）

1. Suite ソースを一次情報として参照する運用を正式に採るか（採るなら参照先とバージョンを固定する）
2. 方針A のアサーションを、実装修正とセットで入れるか、実装修正が終わるまで保留するか
3. 方針C の対応表を維持する余力があるか

## 8. タスク案

- [ ] `oidcc-basic-certification-test-plan` の module 一覧を確定する
      （certification plan のソースを取得するか、`tests/conformance/results/*.zip` の
      実行結果から 35 module の名前を機械的に抽出する）。3 節の 38 件との差分を解消する
- [ ] 方針A: `packages/cli` のテンプレート（`reuseFlowConformanceTestBlock`）に
      refresh 前後の ID Token クレーム比較と access token 一意性のアサーションを追加し、
      全 sample の `conformance.test.ts` を再生成する
      （📌 `study-material/done/token-value-uniqueness-same-second-jwt-reissuance-collision.md` の
      実装修正と順序を調整すること。テスト先行だと CI が赤になる）
- [ ] 方針B: `generateRandomString` の出力文字種が RFC 6749 Appendix A.17 の VSCHAR を満たすこと、
      および複数回呼び出しで値が異なることを `crypto-utils.test.ts` に固定する
- [ ] 方針C: Suite module ↔ テスト層（契約テスト / E2E / Suite 専任）の対応表を作るかを判断し、
      作る場合は置き場所（`basic-op-requirement-traceability.md` か `tests/conformance/README.md`）を決める
- [ ] Suite ソースを一次情報として参照する運用の可否を判断し、採る場合は
      参照した Suite のバージョン（またはコミット）を文書に明記する運用を決める

## 9. 関連ファイル

- 📌 `study-material/done/token-value-uniqueness-same-second-jwt-reissuance-collision.md` — 本ファイルが
  例示する具体的な不具合（本ファイルは「なぜ検出できなかったか」を扱う）
- 📌 `study-material/basic-op-conformance-verification-plan.md` — Suite の実行手順
- 📌 `study-material/basic-op-requirement-traceability.md` — 仕様要件のトレーサビリティ
- 📌 `tests/conformance/README.md` — 実行手順と実測記録・manual review 手順
- 📌 `tasks/done/p1-basic-op-static-client-conformance-result-2026-06-21.md` — 直近の実測結果
- 📌 `study-material/done/cli-generated-output-conformance-ci.md` — 生成物の CI 検証
