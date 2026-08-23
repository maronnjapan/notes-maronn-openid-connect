# 同意拒否（`access_denied`）認可エラーフローの E2E / 契約テスト不足

## 1. このトピックで確認したいこと

ユーザーが同意画面で「Deny（拒否）」を押したとき、生成 OP が **OAuth 2.0 / OIDC 仕様どおりに `error=access_denied` を `redirect_uri` へ返す**フロー（`state` の echo、RFC 9207 の `iss` 付与、フラグメントでなくクエリでの返却）が、**実ブラウザ E2E と conformance 契約テストで固定されているか**を確認する。

実装そのものは存在するが（後述）、**E2E 仕様は成功系（Approve）のみ**で、拒否系の回帰テストが無い。本ファイルは「実装済みだが検証で固定されていない」ギャップを、テスト追加の判断材料として整理する。**仕様違反の修正ではなく、検証カバレッジの補完トピック**である。

> 重複回避:
> - 認可エラーの **リダイレクト時 `error_description` 付与** は `tasks/done/p1-authorization-error-description-redirect.md`、**非リダイレクト系のブラウザエラーページ** は `tasks/done/p1-basic-op-authorization-error-page.md` が扱う。本ファイルは **「ユーザー拒否＝`access_denied` のリダイレクト返却」という特定フローの E2E/契約固定** に限定する。
> - `state` の echo 不変条件は `study-material/done/state-roundtrip-echo-invariant.md`、`iss` 付与は `tasks/done/p1-authorization-response-iss.md` を参照（本ファイルは拒否経路でこれらが同時に成立することの検証に絞る）。

## 2. 関連する仕様・基準

仕様共通索引は `study-material/basic-op-requirement-traceability.md` の §3 を参照。本トピック固有の根拠のみ以下に示す。

- **RFC 6749 §4.1.2.1 Error Response** — リソースオーナーがアクセスを拒否した場合、AS は `error=access_denied` を `redirect_uri` のクエリに付けてリダイレクトする。`state` がリクエストにあれば echo する。
  > access_denied: The resource owner or authorization server denied the request.
- **OpenID Connect Core 1.0 §3.1.2.6 Authentication Error Response** — 認可エンドポイントのエラーは RFC 6749 §4.1.2.1 に従う。OIDC 固有の追加エラー（`interaction_required` 等）も同じ返却方式。
- **RFC 9207 §2 OAuth 2.0 Authorization Server Issuer Identification** — 認可レスポンス（成功・エラー双方）に `iss` を含める。拒否レスポンスも対象。
- **OIDC Core §3.1.2.5 / OAuth 2.1 §4.1.2** — エラーは redirect_uri が有効に解決できる場合のみリダイレクトで返す（redirect_uri 自体が不正なら UA に直接エラー表示）。フラグメントではなくクエリで返す（code flow）。

これは **Basic OP 認定の周辺挙動**。認定テストは主に発行・拒否の正当性を見るが、ユーザー拒否経路の堅牢性は実運用の相互運用性に直結する。

## 3. 参照資料

- RFC 6749 §4.1.2.1 — https://www.rfc-editor.org/rfc/rfc6749#section-4.1.2.1 （`access_denied` の定義と返却方式）
- OpenID Connect Core 1.0 §3.1.2.6 — https://openid.net/specs/openid-connect-core-1_0.html#AuthError
- RFC 9207 §2 — https://www.rfc-editor.org/rfc/rfc9207 （認可レスポンスへの `iss` 付与）
- 既存タスク: `tasks/done/p1-authorization-error-description-redirect.md` / `tasks/done/p1-basic-op-authorization-error-page.md` / `tasks/done/p1-authorization-response-iss.md`
- 既存 E2E: `tests/e2e/specs/auth-code-flow.spec.ts`（成功系のみ。"Approve" をクリックし code 受領を検証）

## 4. 現在の実装確認

- **拒否ボタンの描画**: `packages/cli/src/frameworks/web-standard/templates.ts`（同意画面の `<button type="submit" name="action" value="deny">Deny</button>`、L1128 付近）。4 フレームワーク（express/hono/fastify/nextjs）の生成同意画面に存在。
- **拒否ハンドリング**: 同 `templates.ts` のコンセント action（L1175 付近）:
  ```ts
  if (action === 'deny') {
    const denyUrl = new URL(transaction.redirectUri);
    denyUrl.searchParams.set('error', 'access_denied');
    if (transaction.state) {
      denyUrl.searchParams.set('state', transaction.state);
    }
    denyUrl.searchParams.set('iss', issuer);   // RFC 9207 §2
    await transactionStore.delete('auth_txn:' + transactionId);
    await authSessionStore.delete(transactionId);
    redirect(denyUrl.toString());
  }
  ```
  → `error=access_denied` をクエリで付与、`state` を条件付き echo、`iss` を付与、transaction / session を破棄。仕様に沿った実装。
- **core 側の列挙**: `packages/core/src/authorization-request.ts` に `AccessDenied = 'access_denied'`（L24 付近）が定義済み。
- **既存テスト**:
  - CLI ジェネレータ単体テスト（`packages/cli/src/__tests__/web-framework-generators.test.ts` / `hono-generator.test.ts`）に `deny` への参照あり（生成コードに deny 分岐が含まれることの確認レベル）。
  - **E2E（`tests/e2e/specs/`）には deny 経路が無い**（成功系 `auth-code-flow.spec.ts` のみ）。
  - **`conformance.test.ts`（各 sample）に「拒否時に `access_denied` を返す」アサーションが見当たらない**（要最終確認）。

## 5. 現在の実装との差分

- **満たしていること**
  - 拒否時に `access_denied` をクエリで返却、`state` echo、`iss` 付与、transaction/session 破棄まで実装済み。仕様準拠。
- **不足している可能性があること**
  - 実ブラウザでの拒否経路 E2E が無い。生成コードの回帰（例: deny 分岐の取りこぼし、`state` 未 echo、フラグメント返却化）を検出できない。
  - conformance.test.ts に拒否経路の契約アサーションが無いと、利用者が生成コードを改変して挙動を壊しても気づけない（CLAUDE.md の conformance.test.ts の趣旨に照らし弱い）。
- **セキュリティ上の確認点**
  - 拒否時に認可コードやセッションが残らないこと（リソースリーク・誤承認防止）。実装では `delete` 済みだが、テストで固定したい。
  - `redirect_uri` 検証は拒否経路でも先に済んでいること（不正 redirect_uri なら拒否レスポンスもリダイレクトしない）。
- **相互運用性の観点**
  - クライアント側ライブラリは `error=access_denied` + `state` で「ユーザーがキャンセルした」と判定する。echo 漏れやフラグメント返却は RP の検知を壊す。

## 6. 改善・追加を検討する理由

- **価値**: 実装は正しいが、CLAUDE.md は「実ブラウザ・実 HTTP フローで検証できる場合は原則 `tests/e2e` に E2E を追加」「conformance.test.ts は OP の想定挙動を全網羅」と定めている。拒否はブラウザ操作で再現できる主要分岐であり、現状の E2E（成功系のみ）はこの方針に対して穴がある。
- **Basic OP 必須か**: 認定の必須テスト項目ではないが、Fidelity（忠実性）シグナルとして拒否経路の固定は妥当。
- **導入しやすさ**: 既存 `auth-code-flow.spec.ts` が login→consent までの導線を持つため、Approve を Deny に差し替えるだけで大半を流用できる。conformance.test.ts 側も既存の認可フローテストに 1 ケース追加する形。
- **既存実装との接続**: 追加はテストのみ。生成コードの変更は不要（仕様準拠済み）。conformance アサーションを増やす場合は CLAUDE.md に従い **cli 側の生成元** を修正する。
- **実装しない場合のリスク**: 利用者が同意画面をカスタマイズして deny 分岐や `state` echo を壊しても、テストが緑のまま通り、RP のキャンセル検知が静かに壊れる。

## 7. 実装方針の候補

最終判断は人間が行う。

- **方針 A（E2E のみ追加）**: `tests/e2e/specs/` に deny 経路の spec を 1 本追加。Deny クリック → `redirect_uri?error=access_denied&state=...&iss=...` を検証。最小コスト。
- **方針 B（conformance.test.ts にも契約追加）**: cli 側の conformance.test.ts 生成コードに「拒否時 `access_denied` 返却」ケースを追加し、各 sample に反映。利用者の改変検知が強くなる。CLAUDE.md の conformance.test.ts 趣旨に最も合致。
- **方針 C（A+B 両方）**: ブラウザ操作の回帰と契約固定の両方をカバー。推奨度は人間判断。
- **注意**: テストは合格値を一意に固定する（CLAUDE.md テスト規約）。`error` は `'access_denied'` を `toBe`、`state` は送信値と完全一致、`iss` は issuer と完全一致で検証し、`toContain` 等の緩いマッチャを避ける。

## 8. タスク案

- [ ] `tests/e2e/specs/` に deny 経路 E2E を追加（login→consent→Deny→`redirect_uri` のクエリに `error=access_denied` / `state` echo / `iss` を厳密一致で検証）
- [ ] 拒否後に transaction / auth session が破棄され、認可コードが発行されていないことを検証
- [ ] （方針 B/C 採用時）cli 側 conformance.test.ts 生成元に拒否経路の契約ケースを追加し、4 sample へ反映
- [ ] 不正 `redirect_uri` 時は拒否レスポンスもリダイレクトしない（UA 直接エラー）ことの確認ケースを検討
- [ ] `pnpm test:e2e`（および該当 sample の conformance）で緑になることを確認
