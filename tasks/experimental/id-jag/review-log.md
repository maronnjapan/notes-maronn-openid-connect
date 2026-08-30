# レビューログ: id-jag

## Review 1

- **日付**: 2026-08-30（仕様作成日と同日。運用ルール上 Review 1 として扱う）
- **観点**: 仕様の完全性（一次資料の読み違い / 公開 API 案が subpath export で実装可能か / CLI 統合の現実性 / 依存方向 / テスト定義 / 非目標の明確さ / 理解資料の自立性）
- **確認資料**:
  - draft-ietf-oauth-identity-assertion-authz-grant-04 全文（ietf.org アーカイブ、2026-08-30 取得）— §3.1 のクレーム必須性、§4.3 の `audience` REQUIRED、`subject_token_type` の 3 値（id_token / saml2 / refresh_token）、§4.3.4 の `token_type: N_A` と refresh_token SHOULD NOT、§4.4.1 の typ / aud（要素数 1 の配列許容）/ client_id 一致の MUST、§4.4.3 の「同一 ID-JAG の再提示可」、§7 のメタデータ名 2 種、§9.3 / §9.4 の禁止事項を仕様書の記載と突き合わせ、読み違いなしを確認
  - `packages/experimental/src/token-exchange/token-exchange-request.ts` — 合成＋ステップ構成、TokenExchangeError（closed enum 回避）、固定文言の方針が本仕様の設計とそのまま整合することを確認
  - `packages/experimental/src/jarm/response-jwt.ts` — RS256 固定の自前 compact JWS 生成が experimental 内で成立済みであることを確認（ID-JAG 署名が踏襲）
  - `packages/core/src/id-token.ts` — `validateIdTokenHint` が署名 / iss / aud / exp / iat / alg none / 外部鍵ヘッダの全検証を持ち、`JwkSet` を注入できる公開 API であることを確認（発行側 subject_token 検証の委譲先）
  - `samples/hono-cloudflare/src/oidc-provider/routes/token.ts` — 生成済み分岐（token-exchange / device_code）の実物構造と catch 節分岐を確認。ID-JAG の 2 分岐が同型で挿入可能
  - `tests/e2e/playwright.config.ts` — webServer 配列に 2 インスタンス目の OP を追加できる構成であること、`OIDC_CLIENTS_JSON` / ポート / issuer が env で注入されることを確認
- **指摘**:
  1. 当初案では発行側の subject_token 無効を draft §4.3.4.3 の例示どおり `invalid_grant` にしていたが、同じ grant_type（token-exchange URN）を共有する既存 token-exchange 機能が `invalid_request` を使っており、`requested_token_type` の値でエラーコードが変わる契約は混乱を招く
  2. 受領側のアクセストークン寿命を ID-JAG の残存期間で cap する案は、draft §4.4.3（アクセストークン失効後に同じ ID-JAG を再提示する、例示でも grant 300 秒に対しトークン 86400 秒）と矛盾する
  3. E2E を単一 OP の自己信頼で組む案は draft §9.3（同一ドメイン内利用の禁止）に反する
- **修正**:
  1. 発行側の subject_token 検証失敗は `invalid_request`（固定文言）に統一し、draft の例示が非規範であることと設計判断を仕様書のエラー節に明記
  2. 寿命 cap を撤回し、`config.accessTokenExpiresIn` をそのまま使う設計に変更。token-exchange 機能との違いを設計判断として明記
  3. E2E をサンプル OP の 2 インスタンス構成に変更し、同一ドメイン拒否（発行側 / 受領側の二重ガード）を仕様のセキュリティ要件と負のテストに追加
- **残リスク**:
  - draft は -04 であり改版でクレームや必須性が変わり得る（U2 として記録）。experimental 隔離とドキュメントの版数明記で受容する
  - `jwksUri` の fetch を生成コード側に置く判断は、キャッシュ TTL 内の鍵ローテーションで検証失敗が起き得る。PoC 用途の許容範囲としてキャッシュ 300 秒を明記し、理解資料でなくコードコメントで案内する
- **判定**: Pass with changes（指摘 3 件は同日修正済み）
- **次回可能日**: 実装後（実装との整合レビュー）

## Review 2

- **日付**: 2026-08-30（対応範囲拡張の改版と同日）
- **観点**: 対応範囲の拡張（refresh token subject と actor_token）の仕様妥当性とセキュリティ（RT 検証水準の refresh grant との一致 / actor 拡張の draft §9.7 適合 / fail-safe デフォルト / エラー契約の一貫性）
- **確認資料**:
  - draft-ietf-oauth-identity-assertion-authz-grant-04 §4.3.2（RT subject の例）、§4.3.3（RT は「通常の refresh_token grant と同じ方法で検証」する MUST と、subject クレームを新規 Identity Assertion 発行時と同様に組み立てる SHOULD）、§4.4.3（RT による ID-JAG 更新の位置づけ）、§9.7（actor 拡張が考慮すべき点: 無関係トークンによる権威の過大表明、act 導出、開示最小化、sub と act の区別）
  - `packages/core/src/refresh-token-grant.ts` — resolveRefreshToken / validateRefreshTokenUnused（rotation 再利用での family 失効）/ validateRefreshTokenClient / validateRefreshTokenExpiration / validateRefreshTokenSession（online RT の fail-closed）がすべて公開ステップ関数であり、再利用で「同じ方法で検証」を文字どおり満たせることを確認
  - `packages/core/src/token-request.ts` の RefreshTokenInfo — subject / authTime / acr / amr が保存済みで、ID トークン経路と同じ subject 素材を RT から組み立てられることを確認
- **指摘**:
  1. RT subject の検証で rotation 済み RT を単に拒否するだけの案は、refresh grant の再利用検知（family 失効）より弱く、「同じ方法で検証」の draft 要件からも外れる
  2. actor_token をリクエスト形式の検証だけで受ける案は、draft §9.7 が警告する「無関係な、あるいはより信頼の低いトークンの持ち込みによる権威の過大表明」を防げない
  3. 受領側が未知の act をそのまま無視する案は、委譲の記録を黙って消して impersonation に見せる劣化（§9.7 の sub / act 区別の要請に反する）
- **修正**:
  1. core の refresh grant ステップ関数を再利用し、family 失効を含む同一挙動にした（RT は消費しない点だけが refresh grant と異なり、これは draft §4.4.3 の更新パスの前提）
  2. actor_token を「本 OP 発行・認証クライアント宛ての ID トークン」に限定し、subject と同一の検証（validateIdTokenHint）を通した actor の sub だけを act に載せる。既定無効の opt-in とした
  3. 受領側は act を構造検証（sub 必須、ネスト同形）して発行トークンへ必ず引き継ぎ、malformed は invalid_grant で拒否する設計にした
- **残リスク**:
  - RT subject の「requested scopes and audience remain within the authorization context of the Refresh Token」（draft §4.3.3）は、ID-JAG の scope がリソース AS ドメインのものである以上、IdP ドメインの RT scope と直接比較できない。本実装は「RT の grant に openid があること」を authorization context の最低要件とし、scope 上限は従来どおり allowedScopes とリソース AS 側ポリシーに委ねる解釈を採った。draft の改版でこの点が具体化されたら追随する
  - actor の act は 1 段のみ（actor_token 自体が委譲済みであるケースのチェーン発行は未対応）。拡張候補として仕様書に記録済み
- **判定**: Pass with changes（指摘 3 件は同日修正済み）
- **次回可能日**: 実装後（実装との整合レビュー）

## Review 3

- **日付**: 2026-08-30（独自 actor_token 種別対応の第 2 次改版と同日）
- **観点**: `actorTokenResolver` 拡張点の設計妥当性（ライブラリとデプロイ側の責務分担 / 組込み id_token 経路の非バイパス / fail-safe デフォルトの維持 / エラー契約の三値化 / リゾルバ戻り値の信頼境界）
- **確認資料**:
  - RFC 8693 §2.1 — actor_token_type は「actor_token の種別を示す識別子」であり値域を id_token に限定しない（§3 の token type identifiers は例示的列挙で、独自 URI も許される）。id_token 限定は本機能側の制約だったことを確認
  - draft-ietf-oauth-identity-assertion-authz-grant-04 §9.7 — actor 拡張で考慮すべき点（無関係・低信頼トークンによる権威の過大表明、act の導出、開示最小化）は種別に依存しない一般論であり、リゾルバ委譲でも設計上維持できることを確認
  - `packages/experimental/src/id-jag/issue-id-jag.ts` の現行 parse / process — 種別ディスパッチを追加しても、`allowActorTokens` を親スイッチとした既存の gate 構造とエラー契約（固定文言）を保てることを確認
- **指摘**:
  1. リゾルバ設定時に id_token 種別も含めて全種別をリゾルバへ委譲する案は、組込み検証（署名 / iss / aud=認証クライアント / exp / iat）をデプロイ側コードが黙って弱められるバイパス経路になる
  2. リゾルバの戻り値を無検証で `act` クレームに載せる案は、malformed な act の発行と、`sub` / `act` 以外の属性の別ドメインへの越境（§9.7 の開示最小化違反）を許す
  3. リゾルバの失敗をすべて `invalid_request` に丸める案は、デプロイ側の実装バグや依存障害をクライアント起因の 400 に見せ、運用者が異常に気づけない
- **修正**:
  1. `actor_token_type=...:id_token` は常に組込み検証で処理し、リゾルバは id_token **以外**の種別に対してのみ呼ばれる契約にした（非バイパス）。リゾルバ未設定時は従来どおり id_token 以外を拒否する
  2. リゾルバ戻り値に構造検証（`sub` 非空文字列必須、ネストは同形）と正規化コピー（`sub` / `act` 以外の属性を落とす）を入れ、通過した値だけを `act` に載せる設計にした
  3. エラー契約を三値化した: `null` = 無効な actor_token（固定文言の `invalid_request`）/ `IdJagError` = リゾルバの明示的な応答指定（透過）/ その他の例外と malformed 戻り値 = `server_error`（モジュールは Error を投げ、生成コードの共通 catch が 500 にする）
- **残リスク**:
  - リクエスト構造の検証（対応規則・非空・gate）とリゾルバ戻り値の構造検証はライブラリが行うが、**トークン内容の検証水準（署名・失効・帰属確認）はリゾルバ実装者の責務**であり、弱い実装をライブラリ側で強制排除する手段はない。サンプルのデモリゾルバ（自 OP 発行アクセストークンの自ストア照合）を実装指針として資料に掲載して受容する
  - actor と subject の関係性ポリシー（誰が誰の代理を務めてよいか）は引き続き未実装。リゾルバでも act の導出までであり、関係性の許可判断は載らない。拡張候補として仕様書に記録済み
- **判定**: Pass with changes（指摘 3 件は同日修正済み）
- **次回可能日**: 実装後（実装との整合レビュー）

