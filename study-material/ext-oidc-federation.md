# 拡張: OpenID Connect Federation 1.0

## ステータス

🟢 拡張機能 / 未着手

## 1. このトピックで確認したいこと

OpenID Federation 1.0（旧 OpenID Connect Federation 1.0）は、**事前の信頼関係なしに RP と OP が相互認証する**ためのトラストフレームワーク。信頼チェーン（Trust Chain）と Trust Anchor 経由でメタデータを動的検証し、教育・行政・複数組織連携系のユースケースで採用が進んでいる（eduGAIN、欧州の eIDAS 関連、日本のいくつかの研究機関等）。

本リポジトリには関連実装が一切無いため、ここでは:

- Federation 対応の価値があるか
- 対応する場合の最小スコープと既存設計への影響
- Conformance との接続（Federation OP プロファイル）

を判断材料として整理する。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイント:

- **OpenID Federation 1.0**（実装者ドラフト中）:
  - Entity Statement（`https://<issuer>/.well-known/openid-federation`）が必須。OP / RP / TA / IA が JWT 形式の Entity Statement を発行する。
  - Trust Chain: TA → IA → OP までの Entity Statement のチェーンを Subordinate Statement で結ぶ。
  - メタデータ Policy: TA / IA がメタデータの制約を動的に課す（許容 redirect_uri パターン、許容 scope 等）。
  - 自動クライアント登録（Automatic / Explicit Client Registration）: DCR の連邦版。クライアントは事前登録せず、Entity Statement と Trust Chain で OP に動的に認識される。
- **Federation メタデータ拡張**:
  - OP メタデータに `client_registration_types_supported`、`federation_registration_endpoint`、`request_authentication_methods_supported` などが追加。
  - JWKS は **Federation 専用の `federation_jwks`**（federation entity 鍵）と通常の `jwks_uri` を分離する。
- **OIDC Conformance**: Federation 1.0 のテストスイートは別立てで、ID Token 検証や Trust Chain 検証を行う（実装者ドラフト追随中）。

## 3. 参照資料

- OpenID Federation 1.0（最新）: https://openid.net/specs/openid-federation-1_0.html
- 解説（OpenID Foundation 公式記事）: https://openid.net/openid-federation/
- Federation 1.0 認証プログラム（実施可否）: https://openid.net/certification/

## 4. 現在の実装確認

- 該当実装は無い。`.well-known/openid-configuration`（OIDC Discovery）はあるが、`.well-known/openid-federation`（Entity Statement）は無い。
- `ClientInfo` は静的登録のみ。Federation の Automatic Registration / Trust Chain は実装外。
- `packages/core/src/discovery.ts` の `ProviderMetadataConfig` に Federation 系メタデータフィールドは無い。

## 5. 現在の実装との差分

- 🟢 **Basic OP プロファイル要件ではない**: Federation は OIDC Core §15.1 必須に含まれない別仕様。
- 🟢 **広告の整合性は問題なし**: 対応していないため広告もしていない（誤広告は無い）。
- 🟡 **PoC ユーザー層の中でも特殊**: 採用は学術・行政・大規模連携用途に偏る。一般 SaaS では使われない。

## 6. 改善・追加を検討する理由

価値:

- **差別化軸「Speed（最新仕様に最速で追随）」**に最も整合する仕様の一つ。Federation は実装数が限定的（Authlete、コンソーシアム実装、いくつかの OSS 試験実装のみ）で、対応している OSS は希少。
- 「自分の要件がこの仕様で実現できるか」を検証したい利用者にとって、**Trust Chain による動的クライアント認識**を試せる OSS は実質ない。
- Conformance Federation OP プロファイルを通せれば、ブランド価値が大きい。

導入難易度:

- 🔴 **設計影響大**:
  - `ClientResolver` を「Entity Statement と Trust Chain から動的にクライアント像を構築する」モデルに変える必要がある。
  - JWS 検証経路に **Trust Chain の検証**（複数 Entity Statement の連鎖検証）が加わる。
  - メタデータ Policy のマージ規則（許容値の絞り込み）が独自セマンティクス。
- 🔴 **テスト負荷大**: モックの Trust Anchor / Intermediate Authority を立てる必要がある。
- 🟡 **既存資産との接続点**:
  - `validateIdTokenHint` の JWS 検証ロジック（`packages/core/src/id-token.ts`）は Entity Statement の検証に応用可能。
  - `assertHasRs256Key()`、`selectSigningKeyByAlg()` の鍵管理は Federation 鍵にもそのまま使える。

実装しない場合:

- 学術／行政系のユースケース検証は不可。一般 SaaS ターゲットでは差し支えない。

## 7. 実装方針の候補

### 方針A（非対応の明文化・現状維持）

- README / `RELEASE-v0.x-scope.md` に「Federation 非対応、v1.x 以降の検討候補」と明記。

### 方針B（最小: Entity Statement の発行のみ）

- `/.well-known/openid-federation` で **自己署名 Entity Statement**（自分が TA を兼ねる単純構成）を返す実装だけ追加。
- Trust Chain 検証、Automatic Registration は実装しない。
- これだけでも「Entity Statement を取得して self-issued なら受け入れる」シンプルな federation 構成のテストが可能。

### 方針C（フルセット: Trust Chain + Automatic Registration）

- Trust Anchor 設定、Trust Chain 検証、Subordinate Statement、Metadata Policy マージ、Automatic Registration（`automatic` / `explicit`）。
- Conformance Federation OP プロファイル対応を狙う。

### 方針D（コア機能化を見送り、別パッケージ）

- `@maronn-openid-connect/federation` のような追加パッケージとして切り出し、コアパッケージのサイズ・複雑度を上げない。
- 利用者は明示的に依存追加した場合のみ Federation が有効になる。

判断材料:

- リリース戦略（「動くものを早く出す」）から、まず方針 A で v0.x を出し、需要を見て方針 D + 方針 C を後続でやるのが筋。
- 方針 B はテンプレ的に楽だが、「self-issued 単一 OP」では Federation の本質的価値が薄い。
- 方針 C は OSS インパクト大だが工数大。差別化軸（Speed / Fidelity）と合致するなら投資価値あり。

## 8. タスク案

- [ ] 「Federation を v1.x 以降ロードマップに載せるか」を人間が判断
- [ ] 方針 A 採用時: `RELEASE-v0.x-scope.md` に明記、README に「Federation 非対応」一文追加
- [ ] 方針 B 採用時:
  - [ ] Entity Statement 構造体（subject、metadata、`jwks`、`iss`、`sub`、`iat`、`exp`、`authority_hints`）の型定義
  - [ ] `/.well-known/openid-federation` ルート追加（self-issued、署名は既存 RS256 鍵を流用）
  - [ ] テスト: 発行された Entity Statement が `iss === sub`、JWS 検証可能、必須クレームを含むこと
- [ ] 方針 C 採用時:
  - [ ] Trust Chain 検証ロジック（`@maronn-openid-connect/federation` 新パッケージ）
  - [ ] Subordinate Statement のフェッチ / キャッシュ
  - [ ] Metadata Policy マージ
  - [ ] Automatic Client Registration ルート
  - [ ] Conformance Federation OP プロファイル実行プラン
