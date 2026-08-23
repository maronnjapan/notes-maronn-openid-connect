# Refresh で再発行する ID Token の nonce 取り扱い（保持 vs 省略）

## 1. タイトル

`refresh_token` グラントで再発行される ID Token に、初回認可リクエストの `nonce` を
そのまま引き継いでいる現状の挙動が、OpenID Connect Core 1.0 の仕様意図に照らして
妥当かどうかの確認と、`nonce` の取り扱いポリシーの是正検討。

## 2. このトピックで確認したいこと

- 現状、core は `refresh_token` グラントで ID Token を再発行する際、初回認証時の
  `nonce` を `RefreshTokenInfo.nonce` から引き継いで ID Token に格納している。
  コード上のコメントは「OIDC Core 1.0 Section 12.1: refresh で発行する ID Token は
  同じ nonce を持つ **MUST**」と記載しているが、この仕様参照が**正確かどうか**を確認したい。
- `nonce` は本来「認可リクエスト（Authentication Request）」と ID Token を結び付け、
  リプレイ攻撃を防ぐためのワンタイム値である。`refresh_token` グラントには認可リクエストが
  存在しないため、「初回の nonce を再発行 ID Token に毎回詰める」ことが
  - 仕様上要求されているのか（MUST なのか）
  - リプレイ防止という nonce の目的に照らして意味があるのか
  - 相互運用性（RP 側の ID Token 検証）に悪影響を与えないか
  を切り分けたい。
- このトピックは Refresh Token フローの「nonce クレーム」固有の論点であり、
  既存の Refresh 系・nonce 系タスクとは**別の差分**であることを確認する（下記 §3 参照）。

## 3. 関連する仕様・基準

> 共通の nonce 仕様・リプレイ防止の説明は重複させない。初回フロー（authorization_code）の
> nonce バインディング／リプレイ検知の一般論は既存の
> `study-material/id-token-nonce-binding-and-replay.md` を参照。
> Refresh のローテーション／再利用検知・絶対寿命・スコープ縮小は
> `study-material/refresh-token-rotation-replay-grace.md` /
> `tasks/p1-refresh-token-absolute-lifetime.md` /
> `tasks/p1-refresh-scope-offline-access-rotation.md` を参照。
> 本ファイルでは「**refresh 再発行 ID Token における nonce クレームの有無**」という差分のみ扱う。

本トピック固有の根拠：

- **OpenID Connect Core 1.0 §2（ID Token）**: `nonce` は
  「String value used to associate a Client session with an ID Token, and to mitigate
  replay attacks. The value is passed through unmodified from the Authentication Request
  to the ID Token.」と定義される。すなわち nonce は **Authentication Request** から
  ID Token へ「そのまま透過」される値であり、認可リクエストの存在が前提。

- **OpenID Connect Core 1.0 §3.1.2.1（Authentication Request）**: `nonce` は
  認可リクエストのパラメータ。`refresh_token` リクエスト（§12.1）には `nonce`
  パラメータは存在しない。

- **OpenID Connect Core 1.0 §3.1.3.7（ID Token Validation, step 11）**:
  「If a nonce value was sent in the **Authentication Request**, a nonce Claim MUST be
  present and its value checked ...」。RP が nonce を検証するのは
  「自分が認可リクエストで nonce を送った」場合に限られる。refresh のレスポンスを
  RP が検証する局面では、RP 手元に「その時の nonce」は通常存在しない。

- **OpenID Connect Core 1.0 §12.1（Refresh Request）／§12.2（Refresh Response /
  ID Token requirements）**: refresh で ID Token を返す場合の ID Token クレーム要件は
  §12.2 に列挙される。§12.2 が保持を要求するのは
  - `iss`（同一）, `sub`（同一）, `iat`（再発行時刻）, `aud`（同一）, `exp`（新規）
  - `auth_time`（存在する場合は**初回認証**時刻）, `azp`（存在する場合は同一）,
    `acr` / `amr`（存在する場合）
  であり、**`nonce` は §12.2 の保持対象として列挙されていない**。つまり
  「refresh の ID Token は同じ nonce を持つ MUST」という記述を裏付ける条文は
  §12.1 にも §12.2 にも存在しない（現状コードのコメントの仕様参照は誤り）。

- **実運用の慣行（相互運用性の傍証）**: 主要 OP（例: Google, Auth0 など）は
  refresh で再発行する ID Token に nonce を含めない実装が一般的。RP ライブラリも
  refresh 経路では nonce 検証を行わない作りが多い。したがって「省略」が
  相互運用上もっとも無難。

> 注意（不明点として明記）: 「nonce を含めてはならない（MUST NOT）」と断言できる明文も
> §12.2 には無い。正確には「§12.2 は nonce の保持を**要求していない**（OPTIONAL 以下）」。
> よって本件は「MUST 違反」ではなく「①誤った MUST 主張の是正」と
> 「②既定で省略する方が安全・無難」という設計判断の問題として扱う。

## 4. 参照資料

- OpenID Connect Core 1.0
  - §2 ID Token（nonce の定義: 「passed through unmodified from the Authentication
    Request to the ID Token」）
    https://openid.net/specs/openid-connect-core-1_0.html#IDToken
  - §3.1.2.1 Authentication Request（nonce は認可リクエストのパラメータ）
    https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest
  - §3.1.3.7 ID Token Validation（step 11: nonce 検証は「認可リクエストで nonce を
    送った場合」に限る）
    https://openid.net/specs/openid-connect-core-1_0.html#IDTokenValidation
  - §12.1 / §12.2 Using Refresh Tokens / Refresh Response（再発行 ID Token の
    クレーム要件一覧。nonce は列挙されない）
    https://openid.net/specs/openid-connect-core-1_0.html#RefreshTokens
- 本リポジトリ内の関連（重複説明を避けるための参照先）:
  - `study-material/id-token-nonce-binding-and-replay.md`（初回フローの nonce 一般論）
  - `study-material/refresh-token-rotation-replay-grace.md`（refresh 再利用検知）
  - `tasks/done/T-020-refresh-scope-claims-filter.md`（refresh 時のクレーム整形の既定動作）

## 5. 現在の実装確認

`nonce` が初回認証から refresh 再発行 ID Token まで引き継がれる経路:

1. 保存: `packages/core/src/token-request.ts`
   - `RefreshTokenInfo.nonce`（コメント: 「OIDC Core 1.0 Section 12.1: refresh で
     発行する ID Token は同じ nonce を持つ MUST」← **この MUST 主張が誤り**）。
   - `validateTokenRequest()` の refresh 分岐で
     `ValidatedRefreshTokenRequest.nonce = refreshTokenInfo.nonce` として返す。
2. 付与: `packages/core/src/token-response.ts`
   - `generateTokenResponse()` 内、`if (nonce !== undefined) idTokenPayload.nonce = nonce;`
     により、呼び出し側が refresh 由来の `nonce` を渡すと再発行 ID Token に格納される。
3. CLI 生成コード（Token エンドポイント）: refresh 分岐で `ValidatedRefreshTokenRequest`
   の `nonce` を `generateTokenResponse` にそのまま渡している想定
   （`packages/cli/src/frameworks/hono/templates.ts`）。

→ 結果として、ユーザが一度ログインした後に発行される**すべての** refresh 由来 ID Token に、
   初回認可リクエストの古い nonce が固定的に詰められ続ける。

## 6. 現在の実装との差分

満たしていること:
- 初回（authorization_code）フローでの nonce 透過は仕様どおり（§2 / §3.1.3.7）。

不足・是正が必要なこと:
- 🟠 **仕様参照の誤り**: コード／型コメントの「§12.1 ... 同じ nonce を持つ MUST」は
  条文に裏付けが無い。§12.2 は nonce を保持対象に挙げていない。誤った MUST 主張は、
  本ライブラリの「Fidelity（忠実性）」シグナルを損なう。
- 🟡 **nonce の目的との不整合**: nonce は「特定の認可リクエスト ↔ ID Token」の
  ワンタイム束縛でリプレイを防ぐ値。refresh には認可リクエストが無く、古い nonce を
  再利用し続けても**リプレイ防止の意味を持たない**（むしろ「使い回された nonce」になる）。
- 🟡 **相互運用性**: refresh 経路で nonce を検証しない RP が大多数。多くは無視するため
  実害は出にくいが、厳格な RP / 検証ツールが「想定外の nonce が ID Token にある」ことを
  警告・拒否する可能性は排除できない。省略する方が無難。
- 🟢 **Basic OP として**: Basic OP Conformance の refresh 系テストは sub / auth_time /
  iss / aud の保持を確認するが、nonce の保持は要求しない（要再確認・下記タスク）。
  よって nonce 省略は Basic OP 適合性を損なわない見込み。

## 7. 改善・追加を検討する理由

- **Fidelity（忠実性）の維持**: 「最新仕様を忠実に」を掲げる本ライブラリで、条文に
  無い MUST をコメントに書いている状態は信頼性シグナルとして弱い。是正の価値が高い。
- **セキュリティ的に下げない**: nonce を省略してもリプレイ防止能力は下がらない
  （refresh の古い nonce はそもそもリプレイ防止に寄与していない）。むしろ
  「使い回し nonce」という誤解の余地を消せる。
- **導入容易性**: 既存の `generateTokenResponse` は `nonce` を任意引数として受けるだけ。
  「refresh 経路では nonce を渡さない（既定で省略）」に CLI テンプレート側を変えるか、
  core 側で「refresh では nonce を出力しない」明示オプションを足すだけで局所対応できる。
- **利用者メリット**: PoC 開発者が ID Token を観察した際に「refresh でも古い nonce が
  付く」挙動に戸惑わずに済む。仕様学習用途として正しい挙動を示せる。
- **実装しない場合のリスク**: 誤った仕様コメントが残り、利用者が「refresh ID Token に
  nonce 保持は必須」と誤学習する。厳格 RP との相互運用で稀に問題化。

## 8. 実装方針の候補

> 最終判断は人間が行う。ここでは判断材料の整理に留める。

- 方針A（推奨度: 高 / 既定で省略）:
  - core の `RefreshTokenInfo` / `ValidatedRefreshTokenRequest` から nonce 引き継ぎを
    廃止、または「保存はするが refresh 再発行 ID Token には出力しない」を既定にする。
  - メリット: 主要 OP の慣行と一致。誤解の余地が無い。
  - 留意: 「保存」自体（イントロスペクション等）に nonce を使っていないか要確認
    （現状 introspection は nonce を返していない＝影響なし）。
- 方針B（設定で選択可能化）:
  - `generateTokenResponse` に `preserveNonceOnRefresh?: boolean`（既定 false）を追加し、
    互換性のため明示的にオプトインした利用者のみ従来動作を維持。
  - メリット: 破壊的変更を避けつつ既定を安全側へ。
  - 留意: オプション増による API 表面の拡大。
- 方針C（コメント是正のみ・挙動維持）:
  - 仕様参照コメントを「§12.2 は nonce 保持を要求しない。本実装は互換目的で保持している」
    へ訂正し、挙動は変えない。
  - メリット: 最小変更。デメリット: 「使い回し nonce」挙動自体は残る。

共通で必要な確認:
- Basic OP Conformance（refresh 系プロファイル）で nonce 保持/省略のどちらが
  期待されるかを実テストで確認（`study-material/basic-op-conformance-verification-plan.md`
  のフローに乗せる）。
- `auth_time` / `acr` / `amr` / `azp` の保持ロジックは §12.2 準拠で正しいので
  本変更で巻き込まないこと（nonce のみを対象にする）。

## 9. タスク案

- [ ] OIDC Core §12.2 を一次情報で再確認し、「refresh 再発行 ID Token に nonce は
      保持対象でない」ことを確定（`/tech-research` で条文引用を取得）。
- [ ] `packages/core/src/token-request.ts` の `RefreshTokenInfo.nonce` /
      `ValidatedRefreshTokenRequest.nonce` のコメントから誤った「§12.1 ... MUST」を削除し、
      正しい説明（§12.2 は nonce 保持を要求しない）へ訂正。
- [ ] 既定挙動を「refresh 再発行 ID Token では nonce を出力しない」に変更（方針A）か、
      `preserveNonceOnRefresh` オプション化（方針B）かを人間が選択。
- [ ] 選択方針に従い `generateTokenResponse` / CLI テンプレート（Token エンドポイント
      refresh 分岐）を修正。
- [ ] テスト追加（TDD, モック不使用）:
  - [ ] should not include nonce in ID Token issued via refresh_token grant（既定動作）
  - [ ] should still preserve auth_time / acr / amr / azp on refresh（回帰防止）
  - [ ]（方針B採用時）should include original nonce only when preserveNonceOnRefresh is true
- [ ] Basic OP Conformance の refresh プロファイルで nonce 期待値を実機確認し、結果を
      `study-material/basic-op-conformance-verification-plan.md` に追記。
