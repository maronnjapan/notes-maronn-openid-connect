# 拡張機能検討: OAuth 2.0 for First-Party Applications（Authorization Challenge Endpoint）

## 1. タイトル

ネイティブ／ファーストパーティアプリがブラウザを介さずに認可コードを取得するための **Authorization Challenge Endpoint**（`draft-ietf-oauth-first-party-apps`）を、本 OSS の拡張機能として導入する価値と方針の検討。

## 2. このトピックで確認したいこと

- ブラウザリダイレクトを伴わない「ファーストパーティ・ネイティブ体験」での認可取得を、本実装の既存 Authorization Code Flow にどう接続できるか
- 既存の関連トピック（`study-material/ext-ciba.md`、`study-material/ext-native-apps-rfc8252.md` / `ext-oauth-native-apps-rfc8252.md`、`study-material/ext-device-authorization-grant-rfc8628.md`）と**何が違うのか**、重複しない差分はどこか
- まだ RFC 化されていない Internet-Draft であることを踏まえ、本 OSS の差別化軸「Speed（最新仕様への最速追随）」と「Portability / セキュリティ」の観点でどう位置づけるか

## 3. 関連する仕様・基準

- **draft-ietf-oauth-first-party-apps（OAuth 2.0 for First-Party Applications）**: ファーストパーティ（=認可サーバと同じ事業者が提供する信頼されたネイティブアプリ）が、ブラウザにリダイレクトせずネイティブ UI で認証情報を収集し、それを **Authorization Challenge Endpoint** に POST して認可コードまたはエラーを受け取るためのプロファイル。多くのケースで「完全にブラウザレス」な OAuth 体験を実現し、予期しない・高リスク・エラー状況でのみブラウザにフォールバックする設計
  - 新規エンドポイント: **Authorization Challenge Endpoint**（クライアントが初期情報を POST → `authorization_code` または `error`（例: `authorization_required`、追加情報を求める challenge）を返す）
  - challenge/response の往復で MFA・追加同意などをネイティブ UI 上で完結させ、最終的に既存の Token Endpoint で `authorization_code` を交換する
- **既存トピックとの差分（重複回避のための明確化）**:
  - vs **CIBA**（`study-material/ext-ciba.md`）: CIBA は「別デバイスのオーセンティケータ」を使うデカップル認証（バックチャネル）。First-Party Apps は「同一アプリ内」でブラウザレスに完結する点が異なる
  - vs **Device Authorization Grant**（`study-material/ext-device-authorization-grant-rfc8628.md`）: Device Grant は入力制約デバイス向けに別デバイスのブラウザで認可する。First-Party Apps はブラウザ自体を避ける
  - vs **Native Apps BCP（RFC 8252）**（`study-material/ext-native-apps-rfc8252.md`）: RFC 8252 は「ネイティブアプリは**システムブラウザを使え**（埋め込み WebView 禁止）」という BCP。First-Party Apps は信頼されたファーストパーティに限り**ブラウザを使わない**選択肢を与える、いわば RFC 8252 の例外的補完。両者の前提（誰が信頼できるか）の違いを利用者に明示する必要がある
- **セキュリティ上の重要前提**: ブラウザレスにすることで「ユーザーがアドレスバーで正規ドメインを確認する」フィッシング耐性を失う。ドラフトはこの機能を**ファーストパーティ（高信頼）クライアント限定**とし、サードパーティには使わせないことを前提にしている。OSS としてこの制約を強制できる設計にすることが重要

## 4. 参照資料

- draft-ietf-oauth-first-party-apps-03（2026-02、Standards Track、未 RFC、有効期限 2026-09） — https://datatracker.ietf.org/doc/draft-ietf-oauth-first-party-apps/ （Authorization Challenge Endpoint の定義、challenge/response フロー、ファーストパーティ限定の前提）
- 最新編集版 — https://drafts.oauth.net/oauth-first-party-apps/draft-ietf-oauth-first-party-apps.html
- 関連: OAuth 2.0 for Native Apps — RFC 8252（`study-material/ext-native-apps-rfc8252.md` で既出）
- 関連: CIBA / Device Grant（上記 §3 のリンク先既存トピック）
- ※ 本ドラフトは進行中の Internet-Draft。実装着手前に最新版（番号が 03 から進んでいる可能性）を再確認すること

## 5. 現在の実装確認

- 認可コード生成: `packages/core/src/authorization-code.ts`（`createAuthorizationCode`）。現状はブラウザ経由の Authorization Endpoint（`authorization-request.ts` → `routes/authorize.ts`）からのみ発行される
- トークン交換: `packages/core/src/token-request.ts`（`grant_type=authorization_code`）。PKCE 必須、`code_verifier` 検証済み。Authorization Challenge Endpoint が発行したコードも、最終的にこの既存経路で交換できる構造
- 認証トランザクション: `packages/core/src/auth-transaction.ts`（`createAuthTransaction` / `completeAuthTransaction` / CSRF / `checkPromptNone` / `requiresReauthentication`）。challenge/response の状態機械は、この既存トランザクション基盤を流用できる可能性がある
- 現状、Authorization Challenge Endpoint に相当する core 関数・ルートは**存在しない**（grep で `challenge` 該当なし）

## 6. 現在の実装との差分

満たしていること:

- 認可コード発行（`createAuthorizationCode`）と PKCE 付き交換（`token-request.ts`）という「出口」は既に揃っており、Challenge Endpoint は「コードを発行するもう一つの入口」として接続できる
- セッション／トランザクション管理基盤（`auth-transaction.ts`）が challenge の往復状態を保持する受け皿になり得る

不足していること:

- 🔴 Authorization Challenge Endpoint 本体（リクエスト受理 → 認証情報検証 → `authorization_code` or challenge レスポンス生成）が未実装
- 🔴 「ファーストパーティ（高信頼）クライアント限定」を強制するクライアント属性・ポリシー（`ClientInfo` 系に `first_party` 相当のフラグが無い）
- 🟡 challenge レスポンス（`authorization_required` 等のエラーコードと `auth_session` 継続）の表現形式。既存 `AuthorizationError` / `TokenError` とは別系統のため、新しいエラー語彙が要る
- 🟡 RFC 8252（ブラウザ必須）方針との整合説明。利用者が「ネイティブは常にシステムブラウザ」という既存トピックと矛盾しないよう、適用条件のドキュメント分離が必要

## 7. 改善・追加を検討する理由

- **なぜ価値があるか**: モバイル／デスクトップのファーストパーティアプリで「ブラウザに飛ばさないログイン」を検証したい PoC 開発者は多い。現状この体験は IdaaS 各社が独自実装しており、標準ベースで素早く試せるものが少ない。本 OSS の「素早く検証するブリッジ」というコンセプトに合致
- **Basic OP 必須か拡張か**: 完全に**拡張機能**。Basic OP / OIDC Core の必須要件ではない
- **導入しやすさ**: 認可コードの発行と交換という両端が既存実装で揃っているため、「Challenge Endpoint という新しい入口」を足す形で**疎結合に追加**できる。core のロジック層に `handleAuthorizationChallenge` 的な関数を新設し、CLI のコード生成テンプレートに別ルートとして載せる構成が自然
- **導入しにくさ／リスク**: (1) ドラフト段階のため仕様が変わり得る（Speed 軸の宿命）。(2) ブラウザレスゆえフィッシング耐性の前提が変わり、ファーストパーティ限定の強制を誤ると重大なセキュリティ低下を招く。(3) 既存 RFC 8252 トピックと「ネイティブはブラウザを使うべき/使わないべき」で一見矛盾するため、適用条件の明文化が必須
- **利用者メリット**: ネイティブアプリのログイン UX を標準ベースで検証可能。**実装しない場合の制約**: ブラウザレス・ネイティブ体験の検証手段が無く、利用者は IdaaS に直行するしかない（本 OSS の「ブリッジ」価値が一部失われる）

## 8. 実装方針の候補

- 方針A（最小プロトタイプ）: core に `handleAuthorizationChallenge`（リクエスト → クライアントがファーストパーティか検証 → 認証情報を resolver で検証 → 成功なら `createAuthorizationCode` を呼び `authorization_code` を返す／不足なら challenge を返す）を新設。CLI テンプレートに `/authorization_challenge` ルートを追加。MFA 等の多段は最初は単段に限定
- 方針B（段階導入・challenge 往復対応）: `auth-transaction.ts` を拡張し、challenge の `auth_session` を保持して複数往復（パスワード → MFA など）に対応
- 方針C（ドラフト追随は様子見・設計のみ先行）: 仕様が安定するまで実装は保留し、本ファイルで設計の置き場所（接続点）だけ確定しておく
- **共通の必須事項**: いずれの方針でも「ファーストパーティ限定フラグ」を `ClientInfo`/クライアントメタデータに導入し、非ファーストパーティクライアントの Challenge Endpoint 利用を拒否すること

最終的に実装するか、どの方針かは人間が判断する。少なくともドラフトが RFC 化に近づくまでは、Speed 軸の観点で「設計接続点の確定（方針C）」を先に行う選択肢が現実的。

## 9. タスク案

- [ ] 最新ドラフト（draft-ietf-oauth-first-party-apps の最新版）を再取得し、Authorization Challenge Endpoint のリクエスト/レスポンス形式・エラーコードを確定整理する（`/tech-research` 活用可）
- [ ] 本 OSS の `RELEASE-v0.x-scope.md` の Tier 定義に照らし、本拡張を v0.x 対象外（将来）/ 設計のみ先行 のどちらにするか方針決定
- [ ] `ClientInfo` 系に「ファーストパーティ（高信頼）」を表す属性を追加する設計の妥当性を検討する
- [ ] （実装する場合）core に Challenge Endpoint ロジックを新設し、`createAuthorizationCode` / `token-request.ts` の既存経路へ接続する TDD タスクに分解する
- [ ] RFC 8252（`study-material/ext-native-apps-rfc8252.md`）との適用条件の住み分けをドキュメント化する
