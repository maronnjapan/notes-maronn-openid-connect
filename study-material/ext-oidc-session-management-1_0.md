# OpenID Connect Session Management 1.0 対応の検討

## 1. このトピックで確認したいこと

OpenID Connect Session Management 1.0 が定義する以下の機能を、本リポジトリの OP として提供するかどうかを検討する。

- 認可レスポンスでの `session_state` パラメータの返却
- `check_session_iframe` Discovery メタデータの公開
- OP 側にホストする OP iframe（postMessage で `session_state` の変化を RP に伝える）
- OP セッションの存続/失効と `session_state` 値の連動

Basic OP 認定では必須ではないが、SPA から「ユーザーがまだ OP にログインしているか」を判定する標準仕様として広く使われていた。サードパーティクッキー廃止の動きで実用性は大きく下がっているが、選択肢としてどう扱うかを整理する。

なお、ログアウト通知系（Front-Channel / Back-Channel Logout）はすでに以下で扱っているため、本ファイルはそれらと重複しない「セッション同期（polling）」の領域に絞る。

- `study-material/ext-channel-logout-notifications.md`
- `study-material/ext-backchannel-logout-oidc.md`
- `study-material/ext-rp-initiated-logout.md`

## 2. 関連する仕様・基準

### OpenID Connect Session Management 1.0
- セクション 2: Authorization Server から RP への `session_state` 返却
  - `session_state` の値は「Client ID + Origin + OP Browser State + Salt」を入力にしたハッシュであり、ブラウザ側で同じ算出ロジックを実行することで値の差分を検出する設計
- セクション 3: `check_session_iframe` を OP 側でホストし、RP は別オリジンの iframe を埋め込んで `postMessage` で OP セッション状態を問い合わせる
- セクション 4: RP iframe → OP iframe の `postMessage` プロトコル（`client_id session_state` を送信し、`changed` / `unchanged` / `error` を受け取る）
- セクション 5: Discovery メタデータでの `check_session_iframe` の公開

### Basic OP 認定との関係
- OpenID Connect Conformance Profile v3.0 の Basic OP セクションでは Session Management 1.0 のテストは含まれていない（Session OP / Front-Channel OP / Back-Channel OP 等のプロファイルで個別に確認される）
- Basic OP 達成の観点では本機能は **任意**

### 実装上の前提
- セクション 4 のフローは「OP のセッション cookie をサードパーティ文脈の iframe から読める」ことが前提
- 主要ブラウザ（Chrome / Safari / Firefox）は ITP・Third-Party Cookie Phase-Out によりサードパーティクッキーを既定で遮断しており、`check_session_iframe` は **実環境で動作しないケースが増えている**
- 後継として CHIPS / Privacy Sandbox / FedCM などが議論されているが、Session Management 1.0 の代替は確立していない

## 3. 参照資料

- OpenID Connect Session Management 1.0
  https://openid.net/specs/openid-connect-session-1_0.html
  - §2 Creating and Updating Sessions
  - §3 OP iframe
  - §4 RP iframe
  - §5 OP Configuration（`check_session_iframe`）
- OpenID Connect Conformance Profiles v3.0
  https://openid.net/specs/openid-connect-conformance-profiles-3_0.html
  - Basic OP には Session Management は含まれない（参考）
- OAuth 2.0 Security Best Current Practice（RFC 9700、参考）
  https://www.rfc-editor.org/rfc/rfc9700.html
- Third-Party Cookie Phase-Out 関連の状況
  - Chrome: Privacy Sandbox の発表（一次情報は Google Privacy Sandbox 公式ページ）
  - Safari ITP（一次情報は WebKit 公式ブログ）

## 4. 現在の実装確認

- 認可レスポンス生成
  - `packages/core/src/authorization-request.ts`（`validateAuthorizationRequest`）
  - `packages/core/src/auth-transaction.ts`（`completeAuthTransaction`）
  - いずれも `session_state` を返却していない
- Discovery メタデータ
  - `packages/core/src/discovery.ts`（`ProviderMetadata`）
  - `check_session_iframe` フィールドは未定義・未公開
- OP iframe
  - `packages/sample/src/oidc-provider/routes/` に該当ルートなし
- セッション状態の保持
  - `packages/sample/src/op/kv-store.ts` 経由でログインセッションを保持しているが、`session_state` を導出する「OP Browser State」概念は導入されていない

つまり Session Management 1.0 関連の機能は一切未実装。

## 5. 現在の実装との差分

| 観点 | 仕様 | 現状 | 差分 |
|---|---|---|---|
| `session_state` 返却 | 認可レスポンス／ID Token に同伴 | 未対応 | OP セッションをハッシュ化する仕組みが必要 |
| `check_session_iframe` Discovery | OP の Discovery で公開 | 未対応 | フィールド追加と iframe ホスティング |
| OP iframe ルート | OP オリジン上に静的 HTML を提供 | 未対応 | ルート新設＋ `postMessage` 実装 |
| ブラウザ互換 | サードパーティクッキー前提 | n/a | 主要ブラウザで動作不可能なケース多数 |

## 6. 改善・追加を検討する理由

- **メリット**
  - レガシー RP（特に Keycloak / IdentityServer 由来の SPA SDK）との互換性確認に使える
  - 「OIDC 仕様を網羅したい」教育目的では存在価値あり
- **デメリット**
  - サードパーティクッキー前提のため、現代ブラウザでは安定的に動作しない
  - 実装すると「動く前提で書いた SPA が本番ブラウザで動かない」失望を生むリスク
  - FedCM / Privacy Sandbox 等の後継仕様が固まりつつあり、いずれ廃止される可能性

## 7. 実装方針の候補

### 候補 A: 採用しない（推奨度: 高）
- Basic OP 必須でなく、ブラウザ動作が不安定なため省略する
- README に「Session Management 1.0 は意図的に未実装。`logout_token`（Back-Channel）/ `frontchannel_logout_uri` を推奨」と明記
- 必要な利用者は自前で iframe を追加できるよう、`session_state` 算出ヘルパだけを `core` から export する選択肢を残す

### 候補 B: ヘルパ関数だけ提供
- `core` に `computeSessionState(clientId, originUri, opBrowserState, salt)` を export
- Discovery への `check_session_iframe` 追加は **行わない**（嘘の宣言を避けるため）
- iframe をホストするか否かは利用者の判断に委ねる

### 候補 C: フル実装
- OP iframe を `packages/cli` で生成する HTML テンプレートに含める
- Discovery への `check_session_iframe` 公開
- ブラウザ非互換時のフォールバック（Back-Channel Logout に誘導）をドキュメント化

## 8. タスク案

候補 A を採用する場合、タスク化は不要（README への注記のみ）。

候補 B / C を採用する場合は以下を切り出せる:

- `core` 側の `computeSessionState` ヘルパ実装（HMAC-SHA256 ベース、Web Crypto 使用）
- OP セッション ID の再計算用に「OP Browser State」を `kv-store` に保持
- Discovery メタデータへの `check_session_iframe` 追加（候補 C のみ）
- `cli` のテンプレに OP iframe HTML / RP iframe サンプルを追加（候補 C のみ）
- README / docs にブラウザ互換性の注意書きを追加

判断材料:

- 主要 RP SDK（oidc-client-ts, react-oidc-context など）が `session_state` をどこまで実装しているか
- 本リポジトリの OSS 利用者層が SPA をどの程度想定しているか
- Back-Channel Logout（`study-material/ext-backchannel-logout-oidc.md`）と機能重複している箇所をどう住み分けるか
