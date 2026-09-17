# Introspection エンドポイントが public client の client_id 単独提示を「認証済み」として扱う問題

## 1. このトピックで確認したいこと

生成 OP の introspection エンドポイント（RFC 7662 の JSON 応答と、RFC 9701 の署名付き JWT 応答の両方）が、`token_endpoint_auth_method: 'none'` で登録された public client の `client_id` 単独提示を認証成功として扱い、トークンの全属性を開示してよいかを確認する。

## 2. 関連する仕様・基準

- RFC 7662 §2.1: introspection の呼び出し元には認可（クライアント認証または別トークン）を要求する（token scanning 防止）。
- RFC 9701 §5 Note: "An AS compliant with this specification MUST refuse to serve introspection requests that don't authenticate the caller and return an HTTP status code 400"。
- RFC 9701 §8.2: 認証なしへのダウングレード防止。
- RFC 7009 §2.1（対比）: revocation は public client の呼び出しを正当に許す。introspection と revocation で要件が異なる。

## 3. 参照資料

- https://www.rfc-editor.org/rfc/rfc7662#section-2.1
- https://www.rfc-editor.org/rfc/rfc9701
- `study-material/done/introspection-caller-authorization-and-disclosure.md`（開示制御の一般論。同ファイルは「現実装はクライアント認証を必須にしており MUST を満たす」と記すが、その前提は public client 登録時に崩れる。本ファイルはその訂正でもある）
- `study-material/done/public-client-token-revocation-rfc7009.md`（revocation の public client 対応。introspection は明示的にスコープ外とされていた）

## 4. 現在の実装確認

生成 introspection ルート（`packages/cli/src/frameworks/hono/templates.ts` の introspection ルートテンプレート。web-standard 変換で express / fastify / nextjs にも展開）は、token エンドポイントと同じクライアント認証パイプラインを呼ぶ。

- `extractClientCredentials`（`packages/core/src/client-auth.ts`）: body に `client_id` のみなら `method: 'none'` として返す
- `validateClientAuthMethod`: 登録方式が `'none'` なら資格情報の不提示だけを確認して return
- `verifyClientSecret`: 登録方式が `'none'` ならスキップ

このパイプラインは token エンドポイントでは正しい（public client は認証しない、OAuth 2.1 §2.4）。しかし introspection ルートはこの結果の `client_id` を「認証済み呼び出し元」として扱い、RFC 9701 有効時は `restrictIntrospectionResponseToCaller` の同一性判定と応答 JWT の `aud` にそのまま使う。

ルート自身のコメントは「Confidential client only — public clients are out of scope for this template」と述べており、実挙動と矛盾する。生成 conformance テストのダウングレード検証は「client_id 自体が無い」ケースのみを固定しており、`client_id=<public client>` のみのケースは未検証。一方、生成 conformance アプリの testClients には method `'none'` の `c-public` が常に登録されている。

## 5. 現在の実装との差分

- 🔴 public client の client_id は公開情報なので、事実上の未認証呼び出しで introspection が成立する。public client 宛トークン（SPA / ネイティブの標準構成）の sub / scope / exp / aud 等の全属性が開示される。
- 🔴 RFC 9701 経路ではこの開示が「AS 署名付きアサーション」になり、caller 制限（audience 制限）の信頼根拠が自称の client_id になる。§5 の「未認証呼び出しを 400 で拒否（MUST）」に反する。
- 🟠 JSON 経路（RFC 7662）にも同じ穴が従来からあるが、既存資料はどこにも記録していない。
- 🟠 `study-material/done/introspection-caller-authorization-and-disclosure.md` と experimental の仕様書（`tasks/experimental/done/jwt-introspection-response/specification.md`）の準拠主張は「クライアント認証必須」を前提にしており、前提の訂正が要る。

## 6. 改善・追加を検討する理由

introspection は「トークンを提示した者に、そのトークンの中身を教える」エンドポイントであり、呼び出し元の認証が開示制御の唯一の根拠になっている。public client 登録が 1 件でもあれば、その client_id を知る誰もがこの根拠を自称でき、RFC 7662 §2.1 が防ごうとする token scanning がそのまま成立する。Basic OP の必須機能ではないが、introspection を生成する既定構成の穴であり、修正の緊急度は高い。

revocation と違い、introspection を public client に開く仕様上の正当性は無い（RS が呼ぶ想定のエンドポイントであり、public client が自トークンを introspect する必要はない）。拒否一択でよい。

## 7. 実装方針の候補

- 案 A: introspection ルートの認証パイプライン直後に「登録方式が `'none'` のクライアントは `invalid_client`（401）で拒否する」ステップを追加する。JSON 経路・JWT 経路の両方に効く位置に置く。
- 案 B: core に `validateIntrospectionCaller`（confidential 必須）を追加し、生成コードから呼ぶ。core の公開 API が増えるが、resolver 差し替え時にも守られる。
- どちらの場合も、生成 conformance テストへ「public client_id のみの introspection は 401」を追加し、specification.md と `introspection-caller-authorization-and-disclosure.md` の前提記述を訂正する。

## 8. タスク案

- [ ] introspection ルートで public client（登録方式 `'none'`）を `invalid_client` で拒否する（JSON / JWT 両経路）
- [ ] conformance テストに public client_id のみのケースを追加する（4 フレームワーク）
- [ ] specification.md / 既存 study-material の準拠主張の前提を訂正する

→ `tasks/p1-introspection-reject-public-client-caller.md` としてタスク化済み。
