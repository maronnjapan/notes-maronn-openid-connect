# Issuer URL のサブパス（マルチテナント）対応と well-known パス計算

## ステータス

🟡 Minor（運用・相互運用性）/ 未着手

## 1. このトピックで確認したいこと

OIDC Discovery 1.0 §3 / RFC 8414 §3 は、`issuer` 値に**ホスト直下のパス**を含むケース（典型例: `https://example.com/tenant1`）を許容する。これは SaaS / マルチテナント運用で「1ホストに複数 OP」を立てる際の標準パターン。本ライブラリは:

- `validateIssuer`（`packages/core/src/discovery.ts:103-128`）で issuer の URL 構造を検証している（https / query 不可 / fragment 不可）が、**パスの有無は問わない**（=サブパスを許容している）
- だが「issuer にパスがある場合に well-known URI をどう計算するか」「sample / CLI 生成テンプレートのルーティングがそれを正しく扱えるか」は未検証・未文書化

本ファイルでは:

- OIDC Discovery 1.0 と RFC 8414 で well-known URI の計算ルールが**異なる**ことの確認
- 現状の sample / CLI 実装がサブパス issuer 下で破綻するか／回避策はあるか
- マルチテナント OP を Tier A シナリオ（`RELEASE-v0.x-scope.md`「複数サンプルアプリの SSO 体験」）に近づける際に必要な前提整理

既存ファイルとの関係:

- 📌 `study-material/oauth-authorization-server-metadata-rfc8414.md`: RFC 8414 の `/.well-known/oauth-authorization-server` パス計算（§3.1: ホストと issuer パスの間に well-known を**挿入**する）に一文だけ触れている。本ファイルは「マルチテナント運用の差分」として独立して扱う

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md`「3.3」を参照。本トピック固有の根拠:

- **OIDC Discovery 1.0 §3**:
  - `issuer` 値は HTTPS スキームの URL で、query / fragment を含んではならない。**パスを含んでよい**（複数 OP を 1 ホストにデプロイする想定）
  - Configuration Information の取得は `<issuer>/.well-known/openid-configuration`（issuer に well-known を**末尾追加**する単純結合）
- **RFC 8414 §3.1 Authorization Server Metadata Path Construction**:
  - well-known URI は `https://<host>/.well-known/oauth-authorization-server<issuer-path>` の形式で構築する（ホストと issuer のパスの**間**に well-known セグメントを挿入）
  - 例: issuer `https://example.com/tenant1` → メタデータ `https://example.com/.well-known/oauth-authorization-server/tenant1`
  - **OIDC Discovery とは規則が違う**ことに注意（OIDC Discovery 自身は §3 で「末尾追加」と書かれている）。RFC 8414 §3.1 は OIDC Discovery のレガシー扱い（end-of-path）が誤りであった旨を Errata で示唆
- **OAuth 2.1 §3.1**: 認可サーバーは RFC 8414 のメタデータ仕様に従う旨を明示。OAuth 2.1 準拠を掲げる本ライブラリにとって RFC 8414 の path 計算規則は無視できない
- **`iss` クレーム / ID Token §2**: `iss` は OP の発行者識別子であり、**Discovery と完全一致**でなければならない（クライアント側検証の基準）。サブパスを含む issuer を ID Token に乗せて、クライアントが Discovery 経由でメタデータを取得できることが互換性の最低線

## 3. 参照資料

- OpenID Connect Discovery 1.0 §3 — https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderConfig （well-known URI が `<issuer>/.well-known/openid-configuration`）
- RFC 8414 §3 / §3.1 — https://www.rfc-editor.org/rfc/rfc8414#section-3 （well-known URI のパス計算規則: ホストと issuer-path の間に挿入）
- RFC 8414 Errata（OIDC Discovery 1.0 の path 計算に関する補足）— https://www.rfc-editor.org/errata/eid5004
- OpenID Connect Core 1.0 §2 — https://openid.net/specs/openid-connect-core-1_0.html#IDToken （`iss` クレームと Discovery の同一性）
- OAuth 2.1 §3.1 — https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1#section-3.1

## 4. 現在の実装確認

- `packages/core/src/discovery.ts:103-128` `validateIssuer`:
  - HTTPS / localhost 例外 / query 拒否 / fragment 拒否は実装済
  - **path の有無や形式に関する検証ロジックは無い**（= `https://example.com/tenant1` は通過する）
- `packages/sample/src/oidc-provider/routes/discovery.ts:13-30`:
  - エンドポイント URL は `${issuer}/authorize` のように **issuer に末尾追加**で構築。issuer がサブパスを含んでいても問題なく動く（`https://example.com/tenant1/authorize` 等）
  - `jwksUri` も `${issuer}/.well-known/jwks.json` で組み立てており、issuer がサブパスを持つと `https://example.com/tenant1/.well-known/jwks.json` になる
- `packages/sample/src/oidc-provider/app.ts:80-83`:
  - Hono ルートが `/.well-known/openid-configuration` 等の**絶対パス**でマウントされている
  - 利用者がアプリ側で sub-path にマウントすれば（`app.route('/tenant1', oidcApp)`）well-known パスは `/tenant1/.well-known/openid-configuration` になり、OIDC Discovery の規則（末尾追加）に整合する
- `/.well-known/oauth-authorization-server` ルートは未実装（📌 `oauth-authorization-server-metadata-rfc8414.md` 参照）。**マルチテナントで RFC 8414 経路を提供する場合、§3.1 の挿入規則に従ったルーティングが必要**
- ID Token の `iss` クレーム（`packages/core/src/id-token.ts`）: 設定された issuer 文字列をそのまま使用。サブパスを含む issuer も検証エラーにならない

## 5. 現在の実装との差分

満たしていること:

- OIDC Discovery 1.0 §3 の「issuer 末尾に well-known を追加」規則には、サンプル実装が**サブパス issuer でも自動的に従える**形になっている
- `validateIssuer` がサブパスを許容しているため、利用者が `issuer: 'https://example.com/tenant1'` のように設定しても拒否されない
- ID Token の `iss` クレーム生成は issuer 文字列をそのまま使うので、Discovery と同一値で出る

不足・確認が必要なこと:

- 🟡 **RFC 8414 §3.1 の挿入規則は未対応**: `/.well-known/oauth-authorization-server` ルートを将来追加する場合、サブパス issuer 下では「ホストと issuer-path の間に挿入」する必要がある。OIDC Discovery と並走する場合、両方のパスを正しく解決するルーティングは sample / CLI 生成テンプレートで自明ではない
- 🟡 **CLI 生成コードのコメント／サンプル不足**: マルチテナント運用（複数の OP を 1 ホストで稼働させる）を試したい OSS 利用者が、「issuer にサブパスを足せばよい」「Hono の sub-route にマウントすればよい」を発見しにくい。`RELEASE-v0.x-scope.md` の「1ログインで複数サンプルアプリに入れる（SSO の体感）」シナリオで、複数 OP を立てる派生として価値が高い
- 🟡 **`iss` の Discovery 整合確認テストが薄い**: ID Token の `iss` と Discovery の `issuer` が**完全一致**することは仕様の MUST だが、サブパス issuer 下で両者の文字列が一致するか（末尾スラッシュの有無含む）を検証する統合テストは存在しない
- 🟢 **末尾スラッシュ問題**: `https://example.com/tenant1` と `https://example.com/tenant1/` は別 URL として扱われる（RFC 3986）。OIDC Discovery / OAuth クライアントは `iss` を文字列等価で比較するため、Issuer に末尾スラッシュを付けるか否かでクライアントが分かれる。本ライブラリの `validateIssuer` はどちらも通すが、ポリシーが文書化されていない

## 6. 改善・追加を検討する理由

- **マルチテナント PoC の容易化**: 本 OSS の想定ユーザー（PoC 開発者・SME 向けコンサル）は、1台のデプロイで複数 OP を立ち上げて IdaaS 移行前の比較検証を行うシナリオが現実的。サブパス issuer を**正面から扱える**ことで、IdaaS 競合製品との接続性比較を最短で試せる
- **OAuth 2.1 / RFC 8414 への準拠予防線**: RFC 8414 ルートを将来実装する際、サブパス issuer 下の path 計算規則を**実装してから気付く**のは設計負債になる。今のうちに方針を凍結保存しておけば、`oauth-authorization-server-metadata-rfc8414.md` の実装着手時にスムーズに連携できる
- **相互運用性**: 商用 IdP（Auth0、Okta、AWS Cognito 等）はテナント単位で issuer サブパスを使う運用が一般的（`https://<tenant>.auth0.com/`、`https://login.microsoftonline.com/<tenant_id>/v2.0` 等）。本ライブラリで同種の構成を体験できれば「ファネル」価値（IdaaS への移行ガイド）が高まる
- **実装しない場合のリスク**:
  - サブパス issuer の振る舞いが暗黙のままで、利用者が末尾スラッシュ等の罠を踏む
  - `oauth-authorization-server-metadata-rfc8414.md` を実装する際、path 計算の再設計が必要になる
  - マルチテナント PoC 体験が出来ない → IdaaS 比較検証の説得力が下がる

## 7. 実装方針の候補

判断材料を整理する（実装方針は人間が決定）:

- 方針A（ドキュメント整備のみ、最小コスト）:
  - `validateIssuer` のコメントに「サブパス可」を明示
  - README または `study-material/RELEASE-v0.x-scope.md` の関連箇所に、マルチテナント PoC の構成例（Hono の sub-route マウント）を 1 セクション追加
  - 末尾スラッシュ運用ポリシー（推奨: スラッシュなし）を文書化
  - コード変更ゼロ。Tier A 体験への影響なし
- 方針B（CLI 生成テンプレートで sub-route mount を選択肢に）:
  - `packages/cli/src/frameworks/hono/templates.ts` に「サブパスマウント」用バリアントを追加（`/op/tenant1` 等にマウントするテンプレ）
  - 利用者は CLI のオプションでテナント名を指定して 2 つの OP を別パスに生成できる
  - 実装コストは中程度。`RELEASE-v0.x-scope.md` の SSO 体験シナリオ強化に直結
- 方針C（RFC 8414 実装時に併せて対応）:
  - 本ファイルは判断材料の凍結保存に留め、`oauth-authorization-server-metadata-rfc8414.md` の実装タスクが立ち上がった時点で path 計算規則を一緒に組み込む
  - 単独でのコスト負担は無いが、忘却リスクがある
- 方針D（`validateIssuer` でサブパスに対する明示的検証を追加）:
  - 末尾スラッシュ統一（拒否 or 自動除去）、特殊文字制限など、ポリシーを実装で強制する
  - 過度に厳しいと利用者の自由度を奪う。最小限の方針（例: 末尾スラッシュは付けないことを推奨し、付いていれば警告ログ）に留めるなら有用

## 8. タスク案

- [ ] 方針 A/B/C/D のどれを採用するか（または順に積み上げるか）を決定
- [ ]（方針 A 採用時）`packages/core/src/discovery.ts` の `validateIssuer` コメントに「サブパス可」「末尾スラッシュは付けない方針」を明示
- [ ]（方針 A 採用時）README または `RELEASE-v0.x-scope.md` にマルチテナント PoC の構成例（Hono `app.route('/tenant1', oidcApp)`）を追加
- [ ]（方針 B 採用時）CLI テンプレに sub-route mount バリアントを追加（テストも追加）
- [ ]（方針 C 採用時）`oauth-authorization-server-metadata-rfc8414.md` に「実装着手時は本ファイルを参照して §3.1 挿入規則を組み込む」リファレンスを追記
- [ ] サブパス issuer 下で ID Token の `iss` と Discovery の `issuer` が完全一致することの統合テストを追加（実装方針に依らず証跡として）
- [ ] `basic-op-requirement-traceability.md` の Pre-Certification 行（TLS / 環境要件）に「マルチテナント issuer の扱い」状態を追加
