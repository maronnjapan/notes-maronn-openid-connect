# Introspection がセッション終了済みの online refresh token を `active: true` と報告する

## 1. タイトル

Token Endpoint は `sessionId` を持つ Refresh Token（online refresh token）について、束縛先の認証セッションが終了していれば `invalid_grant` で拒否する。
一方 `handleIntrospectionRequest` の `isRefreshTokenActive` は `used` と `expiresAt` しか見ず、`IntrospectionRequestContext` にはセッションを引くための入力も無い。
OP 自身が二度と受け付けないトークンを、Introspection だけが `active: true` と報告する不整合を扱う。

## 2. このトピックで確認したいこと

- online refresh token はログアウトや再ログインでセッションが消えた時点で恒久的に使用不能になる（セッション ID はログインごとにランダムなので復活しない）。その状態のトークンを Introspection が `active: true` と返してよいか
- アイドルタイムアウト軸で確定済みの方針（Token Endpoint と Introspection の `active` 判定を一致させる。`study-material/done/introspection-refresh-token-idle-timeout-active-consistency.md`）を、セッション束縛軸にも展開するか
- アイドルタイムアウトがオプトイン設定なのに対し、online refresh token は生成 OP の既定（`onlineRefreshTokenEnabled: true`）で発行される。既定構成で顕在化する点が既存トピックとの違いである

## 3. 関連する仕様・基準

`active` の定義とクロスエンドポイント一貫性の議論は `study-material/done/introspection-refresh-token-idle-timeout-active-consistency.md` §3 と同じであり、繰り返さない。
本トピック固有の根拠は次の 2 点である。

- **RFC 7662 §2.2**: `active` は "whether or not the presented token is currently active" を示す。セッション終了済みの online refresh token は Token Endpoint で必ず `invalid_grant` になるため、"invalid for other reasons" に該当すると解釈するのが自然
- **RFC 9700 §4.14**: Refresh Token の失効状態は OP の各観測面で一貫していることが望ましい

留保:

- Introspection（RFC 7662）は Basic OP 認定の必須エンドポイントではない。本件は認定ブロッカーではなく Fidelity と観測性の改善
- アイドルタイムアウト軸のタスク（`tasks/p3-introspection-refresh-token-idle-timeout-active-consistency.md`）は未着手のまま残っている。実装時期が重なるなら、`active` 判定への入力追加を一度の変更でまとめる判断もありうる

## 4. 参照資料

- RFC 7662 OAuth 2.0 Token Introspection §2.2 — https://www.rfc-editor.org/rfc/rfc7662#section-2.2
- RFC 9700 OAuth 2.0 Security Best Current Practice §4.14 — https://www.rfc-editor.org/rfc/rfc9700.html
- OpenID Connect Core 1.0 §11（offline_access と "other contexts" の Refresh Token）— https://openid.net/specs/openid-connect-core-1_0.html#OfflineAccess
- 本リポジトリ内: `study-material/done/introspection-refresh-token-idle-timeout-active-consistency.md`（アイドル軸の同型問題。本ファイルはセッション束縛軸の差分）

## 5. 現在の実装確認

- `packages/core/src/introspection.ts:125-129`（`isRefreshTokenActive`）: `used` と `expiresAt` のみを検査する。`RefreshTokenInfo.sessionId` への言及は無い
- `packages/core/src/introspection.ts:64` 付近（`IntrospectionRequestContext`）: `authenticationSessionResolver` に相当するフィールドが無く、呼び出し側がセッション生存の検査を差し込む口も無い
- `packages/core/src/refresh-token-grant.ts:148`（`validateRefreshTokenSession`）: Token Endpoint 側は `sessionId` を持つ RT についてセッションを引き、見つからなければ `invalid_grant`（"The authentication session bound to this refresh token has ended"）で拒否する
- 生成 OP の Introspection 用 resolver（`packages/cli/src/frameworks/hono/templates.ts` の `introspectionRefreshTokenResolver`）: ストアのレコードをそのまま返すだけで、セッションの状態は見ない
- `packages/core/src/introspection.test.ts` / `introspection-steps.test.ts`: `sessionId` に関する検証は無い（grep でヒットせず）

## 6. 現在の実装との差分

満たしていること:

- Token Endpoint 側のセッション生存検証は実装・テスト済み（`validateRefreshTokenSession` と生成 OP の配線、conformance テスト）
- Introspection は `used` / `expiresAt` による判定を正しく行う

不足している可能性があること:

- 🟡 **クロスエンドポイント不整合（既定構成で顕在化）**: ログアウト後の online refresh token を Token Endpoint は拒否するのに、Introspection は RT の絶対寿命（生成 OP の既定は長期）が尽きるまで `active: true` と返す。Introspection を信頼するリソースサーバや監視は、死んだ資格情報を有効と誤認する
- 🟡 アイドルタイムアウト軸と同じ構造の問題だが、こちらは既定で有効な発行モードに起因するため、露出する構成の範囲が広い

## 7. 改善・追加を検討する理由

Token Endpoint とその観測面が同じトークンに矛盾した判定を返す状態は、OP の失効ポリシーを外部から検証できなくする。
特に online refresh token は「ログアウトで止まる」ことを価値として導入した機構であり、その停止が Introspection から見えないままでは、導入意図（セッション終了 = 資格情報の失効）を運用者が確認できない。
アイドル軸のタスクと同じ方向の修正で解決でき、導入コストは小さい。

実装しない場合のリスクは、Introspection ベースのアクセス制御や監査が、実際には使用不能なトークンを有効在庫として数え続けることである。

## 8. 実装方針の候補

最終判断は人間が行う。候補は次のとおり。

- **方針 A**: `IntrospectionRequestContext` に任意の `authenticationSessionResolver` を追加し、`isRefreshTokenActive`（または直前のステップ）で `sessionId` 付き RT のセッション生存を検査する。未指定時は従来挙動（後方互換）。Token Endpoint と同じ resolver を渡せば判定が一致する
- **方針 B**: セッション終了時に当該セッション束縛の RT を明示的に失効（`used=true` 化）するライフサイクル連動にする。Introspection は変更不要になるが、ログアウト処理がストア横断の失効を持つ必要があり、変更範囲が広い
- **方針 C**: 現状を「意図的な非対称」として resolver の JSDoc と実装解説に明文化する（fail-open を許容する判断）

方針 A がアイドル軸のタスク案とも整合し、変更が最小で済む。

## 9. タスク案

- `tasks/p3-introspection-online-refresh-token-session-liveness.md` として切り出す（方針 A ベース）
  - core: `IntrospectionRequestContext.authenticationSessionResolver?` を追加し、`sessionId` 付き RT でセッションが引けなければ `active: false`
  - resolver 未指定かつ `sessionId` 付き RT の扱い（fail-open で従来挙動か、fail-closed か）を決めて JSDoc に明記
  - cli: 生成 OP の introspection ルートに Token Endpoint と同じ `authenticationSessionResolver` を配線
  - conformance テスト: ログアウト後の online RT が `active: false` になることを固定
- アイドル軸タスク（`p3-introspection-refresh-token-idle-timeout-active-consistency.md`）と実装が重なる場合は、`active` 判定への入力追加を一度にまとめてよい
