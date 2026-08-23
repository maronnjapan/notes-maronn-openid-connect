# 署名鍵ローテーションの運用ガイド（JWKS 公開・古い鍵の据置・kid 戦略）

## ステータス

🟡 Major（運用・セキュリティ）/ 未着手

## 1. このトピックで確認したいこと

> **前提条件**: 本ファイルが扱うローテーション手順は「署名鍵が永続化されていること」を前提とする。
> 現在のサンプル OP は起動ごとにエフェメラル鍵を生成しており、そもそもローテーションの対象になる
> 安定した鍵が存在しない。この前段の論点は
> `study-material/done/signing-key-persistence-and-instance-consistency.md`
> （タスク: `tasks/p1-signing-key-persistence-in-samples.md`）で扱う。

`SigningKeyProvider` / `createCachedSigningKeyProvider` / `assertHasRs256Key` / `selectSigningKeyByAlg` のコアは整っているが、
**「実運用で署名鍵をどうローテーションするか」**の手順・タイミング・JWKS と Discovery の連動・古い `kid` のリタイア基準が、利用者に伝わる形で集約されていない。

ここで扱うこと:

- 鍵ローテーションのライフサイクル（生成 → 公開 → 切替 → リタイア）
- JWKS の publish タイミングと、Token 発行への kid 切替タイミングのずれ許容
- 古い kid を JWKS から落とすタイミング（既存トークンの有効期限との関係）
- CLI / sample テンプレでの推奨設定
- 鍵漏洩時の緊急ローテーション手順

既存の関連:

- `tasks/done/T-022-add-sign-keys.md` で複数鍵対応は実装済み
- `tasks/done/T-016-rs256-enforcement.md` で RS256 必須化済み
- `study-material/jwks-endpoint-comprehensive.md` は JWKS の **構造**を扱う（重複しない）
- 本ファイルは **時間軸（運用フロー）**を扱う差分

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイント:

- **OIDC Core §10.1.1 Rotation of Asymmetric Signing Keys**:
  - 鍵ローテーション時、新しい鍵は **発行に使う前から JWKS で publish**しておくべき。
  - クライアントは JWKS をキャッシュするので、JWKS publish と新鍵での発行の間に **キャッシュ伝播時間**を確保（典型 24h〜数日）。
  - 古い鍵は、最後にその kid で署名したトークンの有効期限が切れるまで JWKS に残す。
- **OIDC Discovery 1.0 §3**: `jwks_uri` の `Cache-Control` 推奨は明示されないが、実装ではしばしば 24h レベル。
- **JWT BCP（RFC 8725）§3.2**: `kid` は鍵を一意に指す。鍵を更新しても **同じ `kid` を再利用しない**（同じ kid で鍵だけ変えるとキャッシュした検証者が破綻）。
- **OAuth 2.0 Security BCP**: 鍵漏洩時の対応は「即時 JWKS から削除 → revocation」推奨。漏洩で発行済みトークンが偽造可能なため、AT/RT/ID Token を **全 grant 失効**するのが安全側。

## 3. 参照資料

- OIDC Core §10.1.1 Rotation of Asymmetric Signing Keys: https://openid.net/specs/openid-connect-core-1_0.html#RotateSigKeys
- RFC 7517 JWK: https://www.rfc-editor.org/rfc/rfc7517
- RFC 8725 JWT BCP §3.2（kid のピン）: https://www.rfc-editor.org/rfc/rfc8725#section-3.2

## 4. 現在の実装確認

- `packages/core/src/signing-key.ts`:
  - `SigningKeyProvider`: 単一 active key + 全 registered keys を返せる I/F。
  - `getRegisteredSigningKeys()`: 「active + retired but still verifiable」鍵を返す前提（コメント上は「old → new」順）。
  - `selectSigningKeyByAlg()`: alg ベースで鍵を選ぶ。複数鍵があれば新しい方が勝つ。
  - `createCachedSigningKeyProvider(base, ttlMs)`: TTL ベースのキャッシュ。`getSigningKey()` と `getSigningKeys()` を独立にキャッシュ。
  - `assertHasRs256Key()`: 鍵集合に RS256 が必ず 1 つ以上あることを保証。
- `packages/core/src/jwks.ts`:
  - 公開 JWK 集合を export。`getRegisteredSigningKeys()` 経由ですべての鍵を JWKS に出せる。
- sample / CLI 側:
  - `packages/sample/src/oidc-provider/app.ts`:
    - `getSigningKey()` で active 鍵を、`getRegisteredSigningKeys()` で全鍵を取得し context に保存。
    - JWKS / Discovery / token signing で別経路だが、context に乗せる時点で同期している。
  - 利用者が **複数鍵を返す `SigningKeyProvider` を実装する手順**のドキュメント・サンプルが薄い。

## 5. 現在の実装との差分

満たしていること:

- 複数鍵を JWKS に公開する I/F は揃っている。
- active 鍵切り替え時に古い鍵を JWKS から消さずに残せる構造はある。
- RS256 を常に保持することは `assertHasRs256Key` で起動時にガード。

不足／曖昧:

- 🟡 **ローテーション手順のドキュメント不在**: 「新鍵生成 → JWKS に追加 → クライアントキャッシュ伝播待ち → active 切替 → 古い鍵を残す → 既存 AT 期限切れ → 古い鍵を JWKS から削除」のフローを、利用者がコードを見るだけで再現するのは困難。
- 🟡 **キャッシュ TTL の推奨値が無い**: `createCachedSigningKeyProvider(base, ttlMs)` の `ttlMs` をどの値で設定すべきか（数分？数時間？）の指針が無い。短すぎると secret store 負荷、長すぎるとローテーション伝播遅延。
- 🟡 **`kid` 戦略の指針**: kid をどう命名するか（タイムスタンプ系 / UUID / シーケンシャル）、kid 再利用禁止の明示がない。
- 🟡 **緊急ローテーション手順無し**: 鍵漏洩時に「JWKS から即削除 → 全 grant 失効」を行うための manual / スクリプト手順が CLI に無い。
- 🟡 **アクティブ鍵切替のレース**: `getSigningKey()` の TTL キャッシュと secret store の更新が同期しないと、`getSigningKeys()` には新鍵があるが `getSigningKey()` は古鍵を返す瞬間が発生しうる。逆も然り。

## 6. 改善・追加を検討する理由

価値:

- 本リポジトリの差別化軸「本番志向」「Fidelity（Conformance）」と直結。
- ローテーション失敗は **全クライアントの ID Token 検証が壊れる** ため、致命的な事故になりやすい。手順の言語化は事故防止効果が大きい。
- 既存資産（複数鍵対応）は揃っており、**運用手順だけ詰めれば「動くものを早く出す」リリース戦略と相性が良い**。

導入難易度:

- 🟢 **コード変更不要、ドキュメント中心で達成可能**。
- 🟡 **緊急失効スクリプト（任意）**は新規実装になる。

実装しない場合:

- 利用者が鍵ローテーションを試してハマる → OSS としての信頼性低下。

## 7. 実装方針の候補

### 方針A（運用手順をドキュメント化）

- 本ファイル内に「鍵ローテーション ライフサイクル」「タイムライン例（D-7: 新鍵 publish, D-0: active 切替, D+30: 旧鍵 retire）」「kid 命名規則」「キャッシュ TTL 推奨」「緊急ローテーション手順」を固定。
- CLI テンプレに secret store のサンプル `SigningKeyProvider` 実装を 1 つ提供（KV / D1 / 環境変数）。

### 方針B（ヘルパー追加）

- `packages/core/src/signing-key.ts` に以下を追加（任意）:
  - `rotateActiveKey(provider, newKey)`: 古い鍵をリスト末尾に置きつつ新鍵を active に。
  - `retireKey(provider, kid)`: 指定 kid を JWKS / registered set から落とす（呼び出し側責務）。
- ただし実 store 操作は利用者責務。core はあくまで I/F と推奨手順のみ。

### 方針C（緊急失効スクリプト）

- CLI コマンド `revoke-signing-key <kid>` 相当（rotate + 全 grant 失効）。
- sample / CLI テンプレが KV / D1 ベースの secret store と grant store を持つ前提で、参照実装を提供。

判断材料:

- 方針 A は即時可、効果も高い。
- 方針 B は I/F を増やすので OSS の責務範囲とトレードオフ。
- 方針 C は便利だが利用者のストア構成に依存し、テンプレレベルに留めるのが現実的。

## 8. タスク案

- [ ] 方針 A / B / C をどこまで採るかを人間が判断
- [ ] 方針 A 採用時:
  - [ ] 本ファイルに「鍵ローテーション ライフサイクル図」「タイムライン例」「kid 命名規則」「キャッシュ TTL 推奨」を表で固定
  - [ ] CLI テンプレに「鍵を入れ替える時のチェックリスト」コメントを追加
  - [ ] `study-material/jwks-endpoint-comprehensive.md` から本ファイルへ「運用手順は本ファイルを参照」とリンク
- [ ] 方針 B 採用時:
  - [ ] `rotateActiveKey` / `retireKey` のシグネチャ設計
  - [ ] テスト: rotation 時に古い kid が `getRegisteredSigningKeys()` に残ること、`getSigningKey()` は新鍵を返すこと
- [ ] 方針 C 採用時:
  - [ ] CLI に `revoke-signing-key` 相当のサブコマンド追加
  - [ ] 全 grant 失効（cascade revocation）と JWKS 更新を 1 トランザクションで行う参照実装
  - [ ] テスト: 失効後の検証は失敗、新発行は新鍵で成功
- [ ] 既存 `study-material/jwks-endpoint-comprehensive.md` の `kid` セクションから本ファイルへリンクを追加（重複説明回避）
