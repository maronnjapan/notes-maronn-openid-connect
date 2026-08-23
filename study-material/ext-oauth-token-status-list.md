# 拡張機能検討: Token Status List（`draft-ietf-oauth-status-list`）

## 1. タイトル

JWT/CWT で表現したトークン（ID Token、JWT アクセストークン、検証可能クレデンシャル等）の失効・一時停止状態を、スケーラブルなビットマップで配布する **Token Status List（TSL）** を本 OSS の拡張機能として導入する価値と方針の検討。

## 2. このトピックで確認したいこと

- 「署名済み JWT は本質的にステートレスで即時失効しにくい」という既知の課題に対し、TSL がどのような失効伝達手段を与えるか
- 本実装の既存の失効・状態確認手段（`study-material` / `tasks` で扱う **Token Revocation（RFC 7009）**、**Token Introspection（RFC 7662）**、**Refresh Token Rotation/replay 失効**、`subject-wide-token-invalidation-on-credential-change.md`）と**何が違い、どこを補完するのか**
- 本 OSS が既に検討している **OpenID4VCI**（`study-material/ext-openid4vci-credential-issuance.md`）との連動価値（クレデンシャル失効の標準手段としての TSL）

## 3. 関連する仕様・基準

- **draft-ietf-oauth-status-list（Token Status List, TSL）**: JOSE（JWT）または COSE（CWT）で保護されたトークンの**状態**を表現する仕組み。
  - **Status List**: 各トークンに割り当てたインデックス位置のビット（1 bit で valid/invalid、2 bit 以上で `VALID` / `INVALID` / `SUSPENDED` / 予約値）を並べた配列を、圧縮（zlib DEFLATE）して JWT/CWT に封入し、**Status List Token** として公開エンドポイントで配布する
  - **Referenced Token（被参照トークン）側**: `status` クレーム内の `status_list` オブジェクトに `idx`（自分のビット位置）と `uri`（Status List Token の取得先）を埋め込む。検証者はトークン検証時に `uri` から Status List を取得し `idx` のビットを見て失効状態を判定する
  - スケーラビリティ: 1 つの Status List で数万〜数百万トークンの状態を 1 ファイルで表現でき、CRL 的なリスト配布より圧倒的に軽量。プライバシー面でも「個別トークンの問い合わせ」を発生させない（リスト全体を取得するため、どのトークンを検証中か秘匿できる）
- **既存手段との差分（重複回避のための明確化）**:
  - vs **Token Introspection（RFC 7662）**（既存タスク `tasks/done/p1-token-introspection.md` 等）: Introspection は検証者→AS への**オンライン問い合わせ**。AS 可用性に依存し、検証ごとにラウンドトリップが要り、AS に「誰が何を検証中か」が漏れる。TSL は**オフライン／キャッシュ可能**で AS 問い合わせを伴わない
  - vs **Token Revocation（RFC 7009）**（`tasks/done/p1-token-revocation.md` / `public-client-token-revocation-rfc7009.md`）: Revocation は「失効させる」操作。TSL は「失効状態を**検証者に伝える**」配布手段。両者は補完関係（Revocation で状態を変え、TSL でそれを伝播）
  - vs **Refresh Token Rotation / replay 失効**（`study-material/refresh-token-rotation-replay-grace.md` 等）: あれは内部状態（`used` フラグ）で AS 側が検知する仕組み。検証者（RS）側に署名済みトークンの失効を**伝える**標準手段は別途必要で、それが TSL
  - vs `subject-wide-token-invalidation-on-credential-change.md`: subject 単位の一括失効「トリガ」。TSL はその結果を「どう外部検証者に見せるか」の配布層
- **適用範囲**: TSL は ID Token / JWT アクセストークン（RFC 9068、`study-material/jwt-access-token-rfc9068.md`）／ Verifiable Credential いずれにも適用可能なジェネリックな状態機構

## 4. 参照資料

- draft-ietf-oauth-status-list-20（2026-04 時点、未 RFC） — https://datatracker.ietf.org/doc/draft-ietf-oauth-status-list/ （Status List / Status List Token の構造、`status` クレーム、ビット表現、圧縮、検証手順）
- 最新編集版 — https://drafts.oauth.net/draft-ietf-oauth-status-list/draft-ietf-oauth-status-list.html
- GitHub（OAuth WG） — https://github.com/oauth-wg/draft-ietf-oauth-status-list
- 関連既存トピック: `study-material/jwt-access-token-rfc9068.md`（JWT アクセストークン）、`study-material/ext-openid4vci-credential-issuance.md`（クレデンシャル発行）、`tasks/done/p1-token-introspection.md` / `p1-token-revocation.md`
- ※ 進行中の Internet-Draft。実装着手前に最新版（番号が 20 から進んでいる可能性）を再確認すること

## 5. 現在の実装確認

- JWT アクセストークン発行: `packages/core/src/access-token-issuer.ts`（`createJwtAccessTokenIssuer`）。`status` クレームの付与機構は無い
- ID Token 発行: `packages/core/src/id-token.ts`。同上、`status` クレーム未対応
- Introspection / Revocation: `packages/core/src/introspection.ts` / `revocation.ts`。状態は AS 内部で保持し、オンライン問い合わせ（introspection）または失効操作（revocation）で扱う。**署名済みトークンに状態参照（`status_list`）を埋め込み外部配布する経路は無い**
- Status List Token を生成・配布する core 関数・ルートは**存在しない**（grep で `status_list` / `status list` 該当なし）

## 6. 現在の実装との差分

満たしていること:

- JWT 署名基盤（`signing-key.ts` / `crypto-utils.ts` / `jwks.ts`）が整っており、Status List Token（署名済み JWT）の生成に必要な暗号プリミティブは既に Web 標準 API のみで揃っている（Portability 軸を維持できる）
- トークン発行点（`access-token-issuer.ts` / `id-token.ts`）が明確に分離しており、`status` クレーム注入の差し込み口が特定しやすい

不足していること:

- 🔴 Status List のデータ構造（ビット配列・圧縮・インデックス割当の管理）と、それを保持する Store 契約（`study-material/resolver-and-store-contract.md` の枠組みに沿った新ストア）が未定義
- 🔴 Status List Token を配布する公開エンドポイント（`application/statuslist+jwt`）と、発行トークンへの `status.status_list.{idx,uri}` 注入が未実装
- 🟡 インデックス割当・再利用ポリシー（プライバシー: 連番割当はトークン間の相関を生むため、割当戦略の検討が要る）
- 🟡 失効操作（`revocation.ts`）→ Status List のビット更新 への連動配線が未設計

## 7. 改善・追加を検討する理由

- **なぜ価値があるか**: 「JWT は失効できない（できてもオンライン問い合わせが要る）」は OAuth/OIDC 検証で頻出の悩み。TSL は標準ベースで「オフライン検証可能な失効伝達」を提供し、本 OSS の「仕様を素早く忠実に検証するブリッジ」というコンセプトに合致。特に **OpenID4VCI（クレデンシャル発行）と組み合わせると、クレデンシャル失効の de-facto 標準**として価値が高い
- **Basic OP 必須か拡張か**: 完全に**拡張機能**。Basic OP / OIDC Core の必須要件ではない
- **導入しやすさ**: 署名基盤と発行点が既に整理されているため、(1) Status List Token 生成器、(2) `status` クレーム注入、(3) 配布エンドポイント、(4) 失効連動 の 4 部品を疎結合に追加できる。Web 標準のみ（DEFLATE は `CompressionStream`／`DecompressionStream` で実現可能）で Portability を崩さない
- **導入しにくさ／リスク**: (1) ドラフト段階で仕様変更リスク。(2) インデックス割当のプライバシー設計を誤るとトークン相関を許す。(3) Status List の更新整合（ビット更新の原子性・キャッシュ無効化）に運用設計が要る
- **利用者メリット**: 検証者が AS にオンライン問い合わせせずに失効を判定でき、可用性・プライバシー・スケールが改善。**実装しない場合の制約**: 署名済みトークンの失効伝達手段が introspection（オンライン）に限られ、オフライン検証ユースケース（特に VC）を本 OSS で検証できない

## 8. 実装方針の候補

- 方針A（最小・JWT 形式のみ）: COSE/CWT は後回しにし、JWT 形式の Status List Token と `status` クレーム注入、`/statuslist/{id}` 配布エンドポイント、`revocation.ts` からのビット更新の最小経路を実装。圧縮は `CompressionStream('deflate')` を使用
- 方針B（VCI 連動先行）: `study-material/ext-openid4vci-credential-issuance.md` の検討と歩調を合わせ、クレデンシャル失効の文脈で TSL を設計（VC ユースケースに価値が集中するため）
- 方針C（設計のみ先行・実装保留）: ドラフトが安定するまで、Store 契約（`resolver-and-store-contract.md`）への接続点とクレーム注入口の設計だけ確定させる
- **共通検討事項**: インデックス割当戦略（ランダム化 vs 連番）、Status List のサイズ／分割、キャッシュ TTL（`ttl` クレーム）と失効反映の遅延許容

最終的に実装するか、どの方針かは人間が判断する。VCI を本格検討するフェーズで方針B に合流させるのが、価値とドラフト安定性のバランス上は現実的。

## 9. タスク案

- [ ] 最新ドラフト（draft-ietf-oauth-status-list の最新版）を再取得し、`status` クレーム形式・ビット表現・圧縮・配布メディアタイプ（`application/statuslist+jwt`）を確定整理する（`/tech-research` 活用可）
- [ ] `RELEASE-v0.x-scope.md` の Tier に照らし、v0.x 対象外（将来）／設計のみ先行 を方針決定
- [ ] `study-material/resolver-and-store-contract.md` の枠組みに沿った Status List Store 契約案を起こす
- [ ] インデックス割当のプライバシー設計（相関耐性）を検討する
- [ ] （実装する場合）Status List Token 生成 → `status` クレーム注入 → 配布エンドポイント → `revocation.ts` 連動 の 4 部品を TDD タスクに分解する
- [ ] `study-material/ext-openid4vci-credential-issuance.md` にクレデンシャル失効手段としての TSL への参照を追記する
