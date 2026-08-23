# 同意取り消し（consent withdrawal）に伴う grant 単位トークン失効の配線

## 1. このトピックで確認したいこと

ユーザーが「特定クライアントへのアクセス許可」を取り消したとき、**すでに発行済みのリフレッシュトークン／アクセストークン（当該 grant の `grantId` 系列）を実際に失効させる**配線が存在するかを確認する。

現状、core には grant 単位でトークン系列を一括失効する仕組み（`revokeTokensByGrantId(grantId)`）がコード再利用検知のために**既に実装されている**。一方で「ユーザーが同意を取り消す」イベントから、この既存プリミティブを呼ぶ動線は定義されていない。本ファイルは、この **既存機構の再利用による低コストな閉ループ化** を判断材料として整理する。

> 重複回避の方針:
> - 同意（grant）の **記録・再利用・取り消し UI/API** の全体像は `study-material/done/consent-grant-persistence-and-management.md` が扱う。本ファイルはそれを前提に、**「取り消し後に発行済みトークンを死なせる」差分のみ**を扱う。
> - subject 全体に対する「この時刻より前のトークンを全部無効化」（全デバイスログアウト・資格情報変更）は `study-material/subject-wide-token-invalidation-on-credential-change.md` が扱う。本ファイルは **client × subject の grant 粒度** に限定する（両者は別レイヤ）。
> - コード／リフレッシュトークン再利用時の cascade 失効そのものは `study-material/done/authorization-code-reuse-cascade-store-semantics.md` を参照。本ファイルは同じ `revokeTokensByGrantId` 機構を**別トリガ（同意取り消し）から呼ぶ**点が差分。

## 2. 関連する仕様・基準

仕様共通索引は `study-material/basic-op-requirement-traceability.md` の §3 を参照。本トピック固有の根拠のみ以下に示す。

- **OpenID Connect Core 1.0 §11 Offline Access** — `offline_access`（= Refresh Token 発行）は同意に基づく。同意の前提が消えた後もトークンが生き続けるのは権限管理上の不整合。
- **OAuth 2.0 Security BCP（RFC 9700）§4.14** — リフレッシュトークンは長命なクレデンシャルであり、セキュリティイベント時に失効できることが推奨される。同意取り消しはその代表的トリガ。
- **RFC 7009 OAuth 2.0 Token Revocation** — クライアント主導の失効 API。本トピックは「**ユーザー（リソースオーナー）主導**」の失効であり、RFC 7009 のクライアント主導失効とは主体が異なる点に注意（RFC 7009 は `revocation.ts` で実装済み）。
- **OAuth 2.0 Grant Management（拡張、未実装）** — grant のライフサイクル API。フル機能は別ロードマップ（`study-material/ext-grant-management-api.md`）。本トピックは Grant Management 拡張を導入せずとも成立する**最小の閉ループ**を対象とする。

これは **Basic OP 認定の必須要件ではない**。Basic OP は Authorization Code Flow の発行側を対象とし、同意取り消し→失効はプロファイル外。ただし「offline_access を発行できる OP」が取り消し後もトークンを生かし続けるのはセキュリティ運用上の欠落であり、**セキュリティ強化トピック**として扱う。

## 3. 参照資料

- OpenID Connect Core 1.0 §11 — https://openid.net/specs/openid-connect-core-1_0.html#OfflineAccess （offline_access と同意の関係）
- RFC 9700 OAuth 2.0 Security Best Current Practice — https://www.rfc-editor.org/rfc/rfc9700 （長命トークンの失効手段）
- RFC 7009 OAuth 2.0 Token Revocation — https://www.rfc-editor.org/rfc/rfc7009 （クライアント主導失効との対比）
- 既存検討: `study-material/done/consent-grant-persistence-and-management.md`（同意の記録・取り消し UI/API。L131「grant 失効 UI/API が無い」、L137「失効が次の prompt=none に即反映されないと silent 認可が通る」、L153 `revokeConsent` 案）
- 既存検討: `study-material/subject-wide-token-invalidation-on-credential-change.md`（subject 単位ウォーターマーク。L23「consent-grant-persistence は grant 粒度、subject ウォーターマークは別」）
- 既存検討: `study-material/done/authorization-code-reuse-cascade-store-semantics.md`（`revokeTokensByGrantId` の cascade 契約）

## 4. 現在の実装確認

- **既存プリミティブ（再利用対象）**: `packages/core/src/token-request.ts`
  - `RefreshTokenResolver.revokeTokensByGrantId?(grantId)`（L279 付近）、`AuthorizationCodeResolver.revokeTokensByGrantId?(grantId)`（L177 付近）。
  - 現状の呼び出し元は**再利用検知のみ**: refresh token 再提示時（L477-479）、authorization code 再利用時（L575-577 付近）に `grantId` 系列を一括失効する。
- **grantId 系列の連結**: 認可コード → アクセストークン → リフレッシュトークン → ローテーション後リフレッシュトークンが同一 `grantId` を共有（`token-request.ts` の `RefreshTokenInfo.grantId`、ローテーション時に引き継ぎ）。よって `grantId` 1 つで grant 由来トークンを全て特定できる設計が既にある。
- **同意取り消し側**: `ConsentResolver`（CLI 生成 `samples/*/src/oidc-provider/resolvers.ts` / `store.ts` の consent store）。`consent-grant-persistence-and-management.md` の採用方針 A で `recordConsent`/`revokeConsent` を追加する想定だが、**`revokeConsent` から `revokeTokensByGrantId` を呼ぶ動線は未定義**。
- **欠落点**: 同意レコードと `grantId` の対応付け（どの grant が当該 client×subject の同意で発行されたか）を保持していない。現状 consent は `(subject, clientId, scopes)` 粒度で、発行した `grantId` を索引していない。

## 5. 現在の実装との差分

- **満たしていること**
  - grant 単位の一括トークン失効プリミティブ（`revokeTokensByGrantId`）が core に存在し、再利用検知で実績がある。
  - `grantId` がコード→AT→RT→ローテーション後 RT を貫通して連結されている。
- **不足している可能性があること**
  - 同意取り消し（`revokeConsent`）から発行済みトークン系列を失効する動線が無い。取り消し後も既存 RT/AT が満了まで有効。
  - consent レコードに、その同意で発行された `grantId`（複数あり得る）を索引する仕組みが無い。
- **セキュリティ上、改善した方がよいこと**
  - 「このアプリのアクセスを解除」をユーザーが押しても、攻撃者が既に盗んだ RT を使い続けられる窓が残る。offline_access を発行できる OP では実害が大きい。
  - consent 取り消しが次回 `prompt=none` には反映されても（既存検討 L137）、**既発行トークンには反映されない**非対称が生じる。
- **相互運用性の観点**
  - 主要 IdP（Google「サードパーティ アクセス削除」等）は取り消し時にトークンを失効する。利用者が PoC でこの挙動を再現できないと本番想定の検証ができない。
- **Basic OP として提供する上で確認すべきこと**
  - Basic OP 認定の対象外であり、認定可否には影響しない。拡張的なセキュリティ機能として位置づける。

## 6. 改善・追加を検討する理由

- **入れる価値**: 既存の `revokeTokensByGrantId` を再利用するだけで「同意取り消し→トークン失効」の閉ループが成立する。新規の暗号・プロトコルは不要で、追加コストが小さい割にセキュリティ価値が高い。
- **Basic OP 必須か拡張か**: **拡張**。Basic OP プロファイル外。ただし offline_access（refresh token）を提供する OP の運用前提としては実質必要。
- **導入しやすさ**: cascade 失効機構・`grantId` 連結・consent resolver の取り消し案（方針 A）という素材が既に揃っている。欠けているのは「consent ↔ grantId の索引」と「`revokeConsent` 内での失効呼び出し」の 2 点のみ。
- **既存実装との接続**: `ConsentResolver.revokeConsent(subject, clientId)`（`consent-grant-persistence-and-management.md` 方針 A）の実装内で、対応する `grantId` 群を引き、`revokeTokensByGrantId` を呼ぶ。core 側 API は追加不要、CLI 生成 store 側の配線が中心。
- **利用者・運用者メリット**: 「アクセス解除で即トークン無効化」を PoC 段階で検証可能。侵害時の封じ込めが速い。
- **実装しない場合のリスク**: 取り消し後もトークンが満了まで生存。盗難 RT の継続利用窓が残り、ユーザーの「解除した」という期待と挙動が乖離する。

## 7. 実装方針の候補

最終判断は人間が行う。以下は判断材料。

- **方針 A（consent レコードに grantId 群を索引）**
  - consent store に `(subject, clientId) → grantId[]` を保持し、`revokeConsent` で各 `grantId` に `revokeTokensByGrantId` を適用。
  - 長所: grant 粒度で正確に失効。subject ウォーターマークと独立。
  - 短所: 発行時に consent ↔ grantId の追記が必要。store スキーマが増える。
- **方針 B（subject ウォーターマーク機構へ寄せる）**
  - `subject-wide-token-invalidation-on-credential-change.md` のウォーターマークを client 単位に拡張し、`(subject, clientId)` 単位の「この時刻以前は無効」を持つ。
  - 長所: トークンに `grantId` 索引が無い store でも時刻比較で失効判定できる。
  - 短所: 当該ファイルの設計と統合が前提。grant 単位より粒度が粗い場合がある。
- **方針 C（Grant Management 拡張に委ねる）**
  - `ext-grant-management-api.md` のフル実装で grant ライフサイクルを統括。
  - 長所: 標準準拠で API も整う。短所: スコープが大きく、最小閉ループには過剰。
- **共通の注意**: store の結果整合性（KV の eventual consistency）では失効反映が遅延する。`resolver-and-store-contract.md` の失効反映契約に従わせること（既存検討 L178 と同旨）。

## 8. タスク案

- [ ] consent ↔ `grantId` の対応付けをどこで持つか決定（方針 A: consent store に索引 / 方針 B: ウォーターマーク / 方針 C: Grant Management）
- [ ] 採用方針に基づき、`ConsentResolver.revokeConsent`（または同等の取り消し動線）から既存 `revokeTokensByGrantId` を呼ぶ配線を CLI 生成テンプレ（`packages/cli/src/frameworks/*/templates.ts`）に追加
- [ ] CLI 生成 store の参照実装に「アクセス解除」例を追加（生成コードは cli 側を修正）
- [ ] テスト: 同意取り消し後に当該 grant の RT/AT が `invalid_grant` / introspection `active:false` になることを検証
- [ ] テスト: 別 client の同 subject トークンが影響を受けないこと（grant 粒度の隔離）
- [ ] `conformance.test.ts` 生成元への影響有無を確認（OP の対外挙動が変わる場合は cli 側のテンプレと各 sample を更新）
