# 拡張機能検討: OAuth 2.0 Transaction Tokens（Txn-Tokens）

## 1. タイトル

OAuth 2.0 Transaction Tokens（`draft-ietf-oauth-transaction-tokens`）の調査・導入検討。
外部リクエスト（API 呼び出し等）を信頼ドメイン内のマイクロサービス連鎖（Call Chain）で処理する際に、**ユーザー identity・ワークロード identity・認可コンテキストを連鎖全体で保持・伝播**するための短命トークン（Txn-Token）を発行する仕組み。RFC 8693 Token Exchange を土台にする。

## 2. このトピックで確認したいこと

- 本リポジトリ（OIDC Provider コア）にとって Txn-Token は「Provider が直接担う機能」ではなく、**信頼ドメイン内の Transaction Token Service（TTS）が担う別レイヤ**である。それでも、本リポジトリが提供する Token Exchange（RFC 8693）検討（📌 `study-material/ext-token-exchange-rfc8693.md`）の延長として、TTS 役割をオプションで実験できるかを確認する。
- Basic OP / OIDC Core からは外れる純粋な拡張であり、優先度・スコープ妥当性（v0.x に入れるべきか）を判断材料として整理する。
- 既存の Token Exchange トピックと**重複しない差分**（= 連鎖全体でのコンテキスト保持・`txn_token` 型・不変性要件）に絞って記載する。

## 3. 関連する仕様・基準

> Token Exchange（RFC 8693）の基礎（`grant_type=...token-exchange`、`subject_token` / `actor_token`、`requested_token_type` 等）は `study-material/ext-token-exchange-rfc8693.md` を参照し、ここでは Txn-Token 固有の差分のみ記す。

`draft-ietf-oauth-transaction-tokens`（本ファイル作成時点の最新は **draft-08**）の要点:

- 目的: 外部リクエストの処理中、信頼ドメイン内の Call Chain（API ゲートウェイ → サービスA → サービスB …）を通じて、**呼び出し開始時のユーザー／ワークロード identity と認可コンテキストを改ざんなく伝播**する。各ホップで個別の長命アクセストークンを使い回す代わりに、要求単位で短命な Txn-Token を用いる。
- 取得方法: **Transaction Token Service (TTS)** に対する Token Exchange リクエスト。
  - `grant_type` は `urn:ietf:params:oauth:grant-type:token-exchange`（MUST）。
  - `requested_token_type` は `urn:ietf:params:oauth:token-type:txn_token`（MUST）。
  - 入口で受け取った外部トークン（OIDC アクセストークン等）を `subject_token` として提示し、TTS が検証のうえ Txn-Token を発行する（Token Request / Token Response パターン）。
- 性質:
  - Txn-Token は JWT で、要求（transaction）に固有の不変コンテキスト（発行時の identity・認可コンテキスト）を含み、Call Chain 内で**置換・拡張されない一貫性**を保つことが狙い。
  - 短命であり、信頼ドメイン**内部**でのみ通用する（外部公開トークンとは役割が異なる）。
  - 後続ホップは Txn-Token を提示しつつ、必要に応じて自サービスのコンテキストを付加する派生（replacement token）を TTS から得るモデルが規定される。
- 派生動向: `draft-oauth-transaction-tokens-for-agents`（エージェント型ワークロード向けに Txn-Token へエージェントコンテキストを伝播する拡張）が別途検討されている。

## 4. 参照資料

- IETF OAuth WG, "Transaction Tokens", `draft-ietf-oauth-transaction-tokens`（最新 -08。-06 は 2025-07 版）
  - データトラッカー: https://datatracker.ietf.org/doc/draft-ietf-oauth-transaction-tokens/
  - 根拠とした内容: Call Chain でのユーザー／ワークロード identity・認可コンテキストの保持目的、`grant_type=urn:ietf:params:oauth:grant-type:token-exchange` 必須、`requested_token_type=urn:ietf:params:oauth:token-type:txn_token` 必須、信頼ドメイン内・短命・一貫性の性質。
- RFC 8693 OAuth 2.0 Token Exchange — https://www.rfc-editor.org/rfc/rfc8693 （土台となる交換フローと型 URN の定義）
- `draft-oauth-transaction-tokens-for-agents`（派生・エージェント向け拡張） — https://datatracker.ietf.org/doc/draft-oauth-transaction-tokens-for-agents/
- 本リポジトリ内: `study-material/ext-token-exchange-rfc8693.md`（Token Exchange の基礎検討。本トピックはその上位ユースケース）

> 注: RFC 化前ドラフトであり、型 URN・クレーム・フローはバージョンで変動しうる。着手時は採用バージョン本文を一次確認すること（本ファイルは draft-08 時点のスナップショット）。

## 5. 現在の実装確認

- 本リポジトリには **Transaction Token Service 相当の実装は無い**。Token Endpoint（`packages/core/src/token-request.ts` / `routes/token.ts`）は `authorization_code` と `refresh_token` グラントのみを処理し、`grant_type=token-exchange` は未対応（明示的に未サポートとして扱われる）。
- ただし Txn-Token の構成部品となる素地は存在する:
  - JWT 署名発行: `packages/core/src/id-token.ts` / `access-token.ts`（RS256/ES256 等の JWS 発行）。
  - クレーム組み立て・スコープ／コンテキスト保持: `token-response.ts`（acr/amr/azp/audience の伝播ロジック）。
  - Token Exchange 自体の検討: `study-material/ext-token-exchange-rfc8693.md`（未実装の検討段階）。

## 6. 現在の実装との差分

満たしていること:
- JWT 発行・署名・クレーム伝播という Txn-Token 生成に必要な低レベル部品は core に揃っている。

不足していること:
- 🔴 `grant_type=token-exchange` 自体が未実装（前提となる RFC 8693 が検討段階）。
- 🔴 `requested_token_type=...txn_token` の処理、TTS としての `subject_token` 検証・Txn-Token 発行ロジックが無い。
- 🔴 信頼ドメイン内トークンと外部公開トークンを役割分離する設計（短命・内部限定・一貫性保証）が無い。

位置づけの差分:
- 🟡 Txn-Token は本来「OIDC Provider」ではなく「TTS」という別コンポーネントの責務。本リポジトリで扱うなら、コア OIDC Provider とは別の**オプション TTS サンプル**として切り出すのが自然で、Basic OP の中核には接続しない。

## 7. 改善・追加を検討する理由

- なぜ価値があるか: マイクロサービス／ゼロトラスト文脈で「長命アクセストークンの使い回しによる過大権限・横展開リスク」を、要求単位の短命 Txn-Token に置き換える設計は、現代的なバックエンド認可の重要トレンド。本リポジトリの「最新仕様を最速で体感」価値に合致する。
- Basic OP として必要か: **不要（純拡張、かつコア OIDC Provider の範囲外）**。優先度は低い。
- 導入しやすさ / しにくさ:
  - しやすい点: JWT 発行部品が揃い、Token Exchange 検討も既にある。
  - しにくい点: TTS は OIDC Provider と別レイヤであり、サンプル全体のアーキテクチャ（信頼ドメイン・複数サービス・Call Chain）を新設する必要がある。最小デモでも「複数サービス間の伝播」を示す土台が要る。
- 既存実装との接続: まず RFC 8693 Token Exchange（📌 `ext-token-exchange-rfc8693.md`）が実装されれば、その `requested_token_type` 分岐に `txn_token` を足す形で自然に乗る。Token Exchange 未実装のうちは Txn-Token も着手不可。
- 利用者メリット: ゼロトラスト連鎖の認可コンテキスト伝播を、外部製品なしに PoC で確認できる。
- 実装しない場合の制約: 大きな制約は無い（コア OIDC Provider の価値は損なわれない）。あくまで先端ユースケースの取りこぼし。

## 8. 実装方針の候補

> AI は最終決定しない。判断材料のみ。

- 方針A（依存順守: まず Token Exchange を実装してから）: RFC 8693 を core に実装後、`requested_token_type` 分岐に `txn_token` を追加。最も筋が良いが前提コストが大きい。
- 方針B（独立 TTS サンプル）: コア OIDC Provider とは分離した `packages/sample` 配下の実験用 TTS として、複数サービスの Call Chain デモごと用意する。学習価値は高いが工数大。
- 方針C（検討のみ・着手保留）: 本ファイルを「ロードマップ後方の調査メモ」として残し、Token Exchange の実装判断が出るまで着手しない。現実的な既定。

決定すべき点（人間判断）: そもそも v0.x / v1.x スコープに入れるか（`RELEASE-v0.x-scope.md` の Tier 定義と突き合わせ。Conformance や Basic OP を優先する方針からは後方が妥当）、Token Exchange 実装を先行条件とするか。

## 9. タスク案

> RFC 化前ドラフト、かつ前提（Token Exchange）未実装のため、現時点では `tasks/` 化しない（検討段階として保持）。前提が整い着手判断が出た場合の作業候補:

- [ ] 前提: RFC 8693 Token Exchange の実装可否・優先度を先に決める（📌 `ext-token-exchange-rfc8693.md`）
- [ ] 採用ドラフトバージョン（-08 以降）を固定し、`txn_token` 型 URN・必須クレーム・replacement token フローを一次確認する
- [ ] TTS をコア OIDC Provider と分離する設計（パッケージ境界・信頼ドメインモデル）を決める
- [ ] （TDD）`subject_token` 検証 → `txn_token` 発行 → Call Chain 後続ホップでの提示・派生のテストを先に書く
- [ ] 最小 Call Chain デモ（2〜3 サービス）を `packages/sample` 配下に用意するか判断する
- [ ] `study-material/basic-op-requirement-traceability.md` には影響なし（Basic OP 範囲外）。拡張ロードマップ一覧にのみ参照を残す

## 関連トピック

- 📌 `study-material/ext-token-exchange-rfc8693.md` — Txn-Token の前提となる Token Exchange の基礎。**先行条件**。
- 📌 `study-material/ext-mtls-rfc8705.md` / `tasks/T-019-dpop.md` — ワークロード／sender-constrained トークンの周辺。信頼ドメイン内トークン保護の設計参考。
