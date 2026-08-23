# ID Token への `nonce` バインディングとリプレイ対策

## 1. タイトル

Authorization Request の `nonce` パラメータを Authorization Code → Token Endpoint → ID Token クレームへと改ざんなく伝搬させ、リプレイ攻撃に対する OP 側の責務を満たす実装の確認。

## 2. このトピックで確認したいこと

- OIDC Core 1.0 §3.1.2.1 / §3.1.3.7 / §2 が定める「`nonce` が Authorization Request に含まれていた場合、ID Token に**同一値**を含めなければならない」要件を、Authorization Code → Token Endpoint の流れで欠落なく満たしているか
- `nonce` の長さ・文字種・推奨エントロピーに関する OP 側のバリデーションが「過剰でも過少でもない」状態か（仕様は値そのものに制限を課さないが、攻撃面として極端な値は弾く余地がある）
- `nonce` を Authorization Code Store に保持する際の漏洩リスク（Store 共有時の他クライアント可視性、ログ流出）を踏まえた取り扱いが妥当か
- 既存タスク／ファイル: `study-material/basic-op-requirements-baseline.md` の `nonce` 言及、`tasks/done/p1-authorization-code-helper.md` の helper 実装、`packages/core/src/id-token.test.ts` の単体テストでカバーされている。本ファイルは **`nonce` 単独トピックとして独立した検討材料**を残すことが目的（仕様説明の重複は避ける）。

## 3. 関連する仕様・基準

共通の Basic OP 仕様索引は `study-material/basic-op-requirements-baseline.md` を参照。本トピック固有の差分:

### 3.1 OIDC Core 1.0 §3.1.2.1（Authentication Request）

- `nonce` は Authorization Code Flow では **OPTIONAL**（ただし RECOMMENDED）。Implicit/Hybrid Flow では **REQUIRED**。
- Authorization Server は受け取った `nonce` を**そのまま** ID Token に格納する MUST。値の変形（trim/lowercase等）は不可。

### 3.2 OIDC Core 1.0 §3.1.3.7 (ID Token Validation)

- RP は ID Token の `nonce` が Authorization Request で送ったものと一致することを検証する MUST。
- これは RP 側の責務だが、OP は「RP が検証可能な状態（リクエスト値そのまま）」で返す義務を負う。

### 3.3 OIDC Core 1.0 §15.5.2（Nonce Implementation Notes）

- RP に「`nonce` は推測困難（cryptographically random）にせよ」と書かれているのみで、OP には特定のエントロピー要件は課されない。
- ただし OP は `nonce` を「RP が選んだ値」として尊重しなければならない（OP が prepend/append/再生成してはならない）。

### 3.4 nonce のライフサイクル（OP 視点）

| ステップ | 仕様要件 | 本リポジトリの該当箇所 |
|---|---|---|
| Authorization Request 受信 | パース・保存 | `packages/core/src/authorization-request.ts` の `ValidatedAuthorizationRequest.nonce` |
| Authorization Code 発行時 | code に紐付けて保持（または code↔nonce 対応表を持つ） | `packages/core/src/authorization-code.ts` の `AuthorizationCodeData.nonce` |
| Token 交換時 | code に紐付いた `nonce` を取り出して ID Token に格納 | `packages/core/src/token-response.ts` の `nonce` 引数 → `idTokenPayload.nonce` |
| ID Token 生成時 | クレームに同一値を含める | `packages/core/src/id-token.ts` の `IdTokenPayload.nonce` |

### 3.5 リプレイ攻撃の OP 責務

- `nonce` は **RP 側のリプレイ対策**であり、OP は値を保存する必要はない（Authorization Code とライフタイムを共にする）。
- ただし OP は **Authorization Code 自体**の単回利用を保証する責務がある（RFC 6749 §4.1.2 / OAuth 2.1 §4.1.3）。これは `tasks/done/p0-token-revocation-on-code-reuse.md` でカバー済み。
- `nonce` を OP 側で「使用済みリスト」として持つ仕様要件は無い（OP の同一 code 単回利用が崩れない限り、`nonce` リプレイは RP 側で検出される）。

## 4. 参照資料

- OpenID Connect Core 1.0 §3.1.2.1 — https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest （`nonce` パラメータ定義、Code Flow は OPTIONAL／Implicit/Hybrid で REQUIRED）
- OpenID Connect Core 1.0 §3.1.3.7 (4–11) — https://openid.net/specs/openid-connect-core-1_0.html#IDTokenValidation （RP 側の `nonce` 検証要件、OP 側は「リクエスト値をそのまま返す」前提）
- OpenID Connect Core 1.0 §2 — https://openid.net/specs/openid-connect-core-1_0.html#IDToken （ID Token クレーム定義、`nonce` の説明: "String value used to associate a Client session with an ID Token, and to mitigate replay attacks"）
- OpenID Connect Core 1.0 §15.5.2 — https://openid.net/specs/openid-connect-core-1_0.html#NonceNotes （Nonce Implementation Notes: RP は cryptographically random、OP は変更しない）
- OAuth 2.1 §4.1.3 — https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1 （Authorization Code 単回利用）
- 本リポジトリの該当箇所: `packages/core/src/authorization-request.ts`, `packages/core/src/authorization-code.ts`, `packages/core/src/token-response.ts`, `packages/core/src/id-token.ts`, `packages/core/src/id-token.test.ts`（"nonce" describe ブロック）

## 5. 現在の実装確認

- **受信**: `packages/core/src/authorization-request.ts` で `nonce` を任意パラメータとして受領し `ValidatedAuthorizationRequest.nonce` に格納。バリデーション（長さ・文字種）は無し。
- **保存**: `packages/core/src/authorization-code.ts` の `AuthorizationCodeData` に `nonce?: string` を持ち、`buildAuthorizationCodeData` で `authorizationResponse.nonce !== undefined` の場合にのみ保存。
- **トークン交換**: `packages/core/src/token-request.ts` で code を解決した後、保存された `nonce` を `generateTokenResponse` に渡す。`packages/core/src/token-response.ts` で `nonce !== undefined` のときのみ `idTokenPayload.nonce` に格納。
- **ID Token 出力**: `packages/core/src/id-token.ts` の `IdTokenPayload.nonce?: string` 経由で JWT クレームに埋め込み。値の改変は無し（仕様準拠）。
- **テスト**: `id-token.test.ts` の `describe('nonce')` で「リクエスト値がそのまま含まれる」「未指定時は欠落」を確認。`token-response.test.ts` でも end-to-end でカバー。
- **`nonce` 必須化（Implicit/Hybrid）の判定**: 本リポジトリは Authorization Code Flow のみサポートのため、`nonce` REQUIRED 化のチェックは現状不要。将来 Hybrid 対応（`study-material/ext-multiple-response-types-hybrid-flow.md`）に進むと REQUIRED 判定が必要になる。

## 6. 現在の実装との差分

満たしていること:

- ✅ Authorization Request → Authorization Code → ID Token への `nonce` 値伝搬は無変形で行われる（OIDC Core §3.1.2.1 / §2 準拠）
- ✅ `nonce` 未指定時は ID Token クレームに含めない（RP 検証時に "either both or neither" を満たす）
- ✅ Authorization Code 単回利用は別タスクで担保済み（`tasks/done/p0-token-revocation-on-code-reuse.md`）

不足・確認が必要なこと:

- 🟡 **`nonce` の長さ・文字種に対する OP 側の防御が無い**: 仕様は OP に制限を課さないが、極端なケース（数 MB の文字列、改行や制御文字の混入）を素通しで保存・署名するとサービス DoS や JWT サイズ膨張につながりうる。`request_object` 経由で巨大 `nonce` を送られた場合の挙動を明示すべき。
- 🟡 **Authorization Code Store の漏洩面**: `nonce` は code と同じ Store に保存される。Store 実装が「読み取り権限を持つ別プロセス」と共有される運用では、`nonce` 流出 → 攻撃者が成りすまし code 交換時に正しい `nonce` を返せる、というシナリオに繋がる。ただし `nonce` だけで攻撃は成立せず（code が必要）、`tasks/done/p0-token-revocation-on-code-reuse.md` で code 単回利用が守られている前提では実害は低い。
- 🟡 **`nonce` を含む `request` / `request_uri` 経由**（拡張機能）: `study-material/ext-jar-request-object-rfc9101.md` で扱うが、JAR/PAR 経由で送られた `nonce` も同じ伝搬経路に流れる必要がある。現状未実装の JAR/PAR が将来導入された際に伝搬テストが必要になる旨を本ファイルから言及しておく。
- 🟡 **`nonce` のログ取り扱い**: `study-material/audit-logging-and-observability.md` と関連。`nonce` は機密ではないが、相関分析の手掛かりとして RP セッションを推測できるため、本番ログにそのまま出すべきかは方針が必要。
- 🟢 **Implicit/Hybrid 未対応**: 現状は Code Flow のみのため `nonce` REQUIRED チェックは不要。Hybrid 拡張時の課題として記録のみ。

## 7. 改善・追加を検討する理由

- Basic OP の中核は ID Token の信頼性であり、`nonce` バインディングが正しく動かなければ RP 側のリプレイ対策が破綻する。
- 値の伝搬自体は実装済みだが「変形しない」「欠落しない」ことを **回帰防止テストで固定する** 余地が残る（既存テストはあるが、`request_uri` / PAR / Hybrid 拡張時に通り抜けて壊れる可能性がある）。
- 利用者（OSS 検証者）が独自に Store を実装する際に、`nonce` の取り扱い責務（漏洩面・ログ・暗号化要否）が暗黙のままだと判断材料が不足する。
- 実装しない場合のリスク: 拡張機能追加時に `nonce` が抜け落ちる回帰が発生しても、現行テストでは検知できない可能性がある。

## 8. 実装方針の候補

- 方針A（最小・現状維持）: 仕様準拠は満たしているため何もしない。本ファイルは「現状追跡」のみとし、Hybrid/JAR/PAR 拡張時のチェックリスト基点として残す。
- 方針B（防御的バリデーション）: Authorization Request 受信時に `nonce` の最大長（例: 512 文字）と制御文字禁止を導入。仕様は禁止していないので「サーバーポリシー」として `study-material/discovery-optional-metadata-fields.md` で広告する形にすることも検討。
- 方針C（伝搬テスト強化）: Authorization Request → Token Response の end-to-end テストを `nonce` の境界値（空文字、長文字列、Unicode、改行含む等）で網羅。今後 JAR/PAR 拡張時の安全網にする。
- 方針D（ドキュメント）: Store 契約ドキュメント（`study-material/resolver-and-store-contract.md` と接続）で「`nonce` を含めて code 全体を機密として扱う」「ログに出さない」「TTL 経過後は確実に消す」を明文化。

最終判断（B のバリデーション閾値、C のテスト粒度、D のドキュメント更新範囲）は人間が行う。

## 9. タスク案

- [ ] `nonce` 伝搬の end-to-end テスト（Authorization Request → ID Token クレーム）を境界値（空、長文字列、Unicode、制御文字）で追加
- [ ] Authorization Request の `nonce` 最大長・制御文字ポリシーを decision として記録（実装するかしないかを含めて方針確定）
- [ ] Hybrid Flow 拡張時に `nonce` REQUIRED 化を強制する受け口を `study-material/ext-multiple-response-types-hybrid-flow.md` のタスクへ反映（クロスリファレンス）
- [ ] JAR/PAR 拡張時に `nonce` が `request` オブジェクト経由でも伝搬することのテスト追加要件を `study-material/ext-jar-request-object-rfc9101.md` / `study-material/ext-pushed-authorization-requests-rfc9126.md` 側のタスク案に追記
- [ ] `study-material/resolver-and-store-contract.md` に「Authorization Code Store は `nonce` を含めて機密扱い」の項目を追加
- [ ] `study-material/audit-logging-and-observability.md` に「`nonce` をログに残すか」の方針を追記
