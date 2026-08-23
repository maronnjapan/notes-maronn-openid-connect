# ID Token の `azp` クレーム発行ポリシーと複数 audience 対応

## 1. タイトル

ID Token の `aud` クレームに複数の audience を含めるケース（OAuth Resource Indicators、追加リソースサーバー向けトークン共有）における `azp`（Authorized Party）クレームの自動付与ポリシーと、現状の単一 audience 設計の文書化。

## 2. このトピックで確認したいこと

- OIDC Core 1.0 §2 が定める「`aud` が複数値のとき `azp` は **REQUIRED**、`azp` は `client_id` と一致させる」要件に対し、本リポジトリの ID Token 発行ロジックがどう対応しているか。
- 現状は `idTokenPayload.aud = clientId` と単一 audience で固定発行しているため `azp` を自動付与する必要が無い。これは「Basic OP の最小発行形態」として正しい挙動だが、**明示的な設計判断としてドキュメント化されていない**。
- `validatePayload`（検証側）は `azp` を厳格にチェックする（aud 複数なら必須・aud に含まれる値）が、発行側で自動付与しないため、**外部から `aud` を複数渡したい場合の API がない**（Resource Indicators 拡張時の接続面が未整理）。
- 既存ファイル: `study-material/ext-resource-indicators-rfc8707.md`（Resource Indicators 拡張）で `aud` 複数化は議論されているが、**`azp` 単独の発行ポリシー**は別軸として未整理。本ファイルで補完する。

## 3. 関連する仕様・基準

### 3.1 OIDC Core 1.0 §2 — ID Token claims

- `aud` (REQUIRED): 文字列または文字列配列。**`client_id` を MUST 含む**。OP は他の audience を含めてよい。
- `azp` (OPTIONAL): Authorized Party。**`aud` が複数値で `client_id` だけでないとき REQUIRED**。値は `client_id`。
- `azp` は将来、複数値でも構わないと議論があったが、現在の Core 1.0 文言は単一値前提。
- 単一 audience（`aud = client_id`）の場合 `azp` は **SHOULD NOT** 含めない方が望ましい（informational; 実装によっては有無で互換性差が出るため省くのが無難）。

### 3.2 OIDC Core 1.0 §3.1.3.7 — ID Token Validation

- RP は `aud` に自分の `client_id` が含まれることを確認 MUST。
- `aud` が複数値の場合、`azp` が存在し、かつ `azp == client_id` を確認 MUST。

### 3.3 OAuth 2.0 Resource Indicators (RFC 8707)

- Authorization Request / Token Request に `resource` パラメータを渡すと、OP が「特定 Resource Server 宛て」の Access Token を発行できる。
- ID Token に複数 audience を入れる用途は OIDC 仕様の主用途ではない（ID Token は基本的に Client 自身に向けたトークン）。Access Token とは扱いが異なる。
- 本リポジトリで `aud` を複数化する現実的シナリオは少ないが、**OIDC を拡張する PoC**（例: ID Token を別マイクロサービスにも渡したい）では発生する。

### 3.4 関連既存ファイル

- `study-material/ext-resource-indicators-rfc8707.md`: `resource` パラメータと Access Token の audience 制御。ID Token の `azp` には踏み込んでいない。
- `tasks/p1-jwt-access-token-aud-default.md`: JWT Access Token の `aud` デフォルト値。ID Token の `aud` とは別文脈。
- `packages/core/src/id-token.ts` の `validatePayload`: `aud` 配列長 > 1 で `azp` が無ければ throw、`azp` が `aud` に含まれていなければ throw。**しかし発行側がここを通過する経路は現状無い**（発行時は単一 audience のため）。

## 4. 参照資料

- OpenID Connect Core 1.0 §2 — https://openid.net/specs/openid-connect-core-1_0.html#IDToken （`aud` / `azp` の定義: "aud REQUIRED — MUST contain the OAuth 2.0 client_id of the Relying Party"、"azp OPTIONAL — Authorized party — the party to which the ID Token was issued. If present, it MUST contain the OAuth 2.0 Client ID of this party. ... It is needed when the ID Token has a single audience value and that audience is different than the authorized party. It MAY be included even when the authorized party is the same as the sole audience."）
- OpenID Connect Core 1.0 §3.1.3.7 (3–5) — https://openid.net/specs/openid-connect-core-1_0.html#IDTokenValidation （RP 側の `aud`/`azp` 検証要件）
- OAuth 2.0 Resource Indicators RFC 8707 — https://datatracker.ietf.org/doc/html/rfc8707 （`resource` パラメータ、Access Token の audience 制御。ID Token への影響は限定的）
- 本リポジトリ該当箇所: `packages/core/src/id-token.ts`（`validatePayload` の `azp` 検証ブロック）、`packages/core/src/token-response.ts`（`idTokenPayload.aud = clientId` のハードコード）

## 5. 現在の実装確認

- **ID Token 発行**: `packages/core/src/token-response.ts` で `idTokenPayload.aud = clientId` と単一値固定。`audience` 引数（複数値受け取り）は **Access Token 専用**（同ファイルの `accessTokenAud` のみで参照、ID Token には流れない）。
- **`azp` 自動付与なし**: 発行ロジックに `azp` をセットする経路が存在しない。
- **検証側は厳格**: `id-token.ts` の `validatePayload` が `Array.isArray(aud) && aud.length > 1` で `azp` REQUIRED、`azp ∈ aud` を MUST 検証。
- **テスト**: `id-token.test.ts` には `azp` 関連の単体テストが存在（`validatePayload` 側）。発行側（多 audience の意図的発行）は API が無いためテストも無い。
- **Discovery**: `azp` を広告するメタデータは Discovery 標準フィールドに無いため広告不要。

## 6. 現在の実装との差分

満たしていること:

- ✅ 単一 audience で `aud = client_id` を必ず満たす（Basic OP の最小要件）
- ✅ 検証側は OIDC Core §3.1.3.7 (4–5) の `aud`/`azp` 規則に厳格に対応
- ✅ `aud` に「`client_id` のみ」を入れる現状の発行形式は OIDC Core §2 informational の "SHOULD NOT add azp" 推奨と整合（`azp` を入れない = 余計な互換性差を避ける）

不足・確認が必要なこと:

- 🟡 **設計判断の暗黙化**: 「単一 audience 固定」「`azp` 不付与」は仕様準拠だが、**意図的な設計判断**としてコードコメント・ドキュメントに残っていない。利用者が拡張時に「ID Token の `aud` を複数にしたい」と思った際の入口が無く、`token-response.ts` を直接編集するしかない。
- 🟡 **検証ロジックとの非対称**: 発行側は単一値しか出さないのに、検証側は複数値を想定したコードを持つ。この非対称は OIDC Core 準拠のためであり問題ないが、コード上で「発行は単一、検証は複数想定（外部 ID Token の `id_token_hint` で来る可能性）」と明示されていると親切。
- 🟡 **Resource Indicators 拡張との接続面**: `ext-resource-indicators-rfc8707.md` が将来実装される際、Access Token の `aud` 複数化が起点になるが、ID Token への波及（`azp` 自動付与の要否）が現状未整理。
- 🟡 **`azp` 「単一 audience でも入れて良い」条項の扱い**: Core §2 informational では "MAY be included even when the authorized party is the same as the sole audience" とされる。意図的に常に `azp = client_id` を付ける選択肢もあり、これは RP 検証ロジックの統一化に寄与する。本リポジトリでは「入れない」選択を取っているが、`azp` を含めるオプションを設けるかは判断材料が必要。

## 7. 改善・追加を検討する理由

- Basic OP の中核は ID Token の検証規則であり、`azp` ルールに対する OP 側の発行ポリシーが明文化されていることが「仕様検証ブリッジ」としての説明責任に直結する。
- 利用者が「ID Token の `aud` を複数にしたい」と思ったとき、**仕様準拠で安全に拡張できる入口**が必要。現状は `token-response.ts` を直接いじる以外なく、改変時の `azp` 自動付与忘れで仕様違反 ID Token を吐く事故が起きやすい。
- 実装しない場合のリスク: Resource Indicators や独自拡張で `aud` を複数化した瞬間、`azp` 不在の不適合 ID Token が発行され、厳格な RP（IdP-IdP 連携用途）で検証失敗する。
- 導入しやすさ: 発行 API に `audience` を渡せる経路（Access Token 既存）を ID Token にも展開し、複数値時に `azp` を自動付与する小さな分岐で実現可能。core の責務は最小化したまま resolver/設定での拡張余地を残せる。

## 8. 実装方針の候補

- 方針A（現状維持＋明示化）: コードコメントと本ファイルで「ID Token は単一 audience 固定、`azp` 不付与」を Basic OP の意図的な設計判断として明文化。Resource Indicators 拡張時に再評価する旨を残す。
- 方針B（拡張インターフェース整備）: `TokenResponseOptions` に `idTokenAdditionalAudiences?: string[]` を追加し、指定があれば `aud = [clientId, ...additional]`、長さ > 1 のとき `azp = clientId` を自動付与。API は opt-in なので Basic OP デフォルト挙動は変えない。
- 方針C（`azp` 常時付与オプション）: `alwaysIncludeAzp?: boolean` 設定を入れ、true なら単一 audience でも `azp = client_id` を付ける。一部の厳格な RP 検証ライブラリとの相互運用性向上を狙う（informational MAY の活用）。
- 方針D（テスト追加のみ）: 発行 ID Token が常に「`aud` 単一・`azp` 不在」となることを回帰テストで固定し、`azp` 仕様要件は検証側テストに任せる。

最終的に B/C を入れるか、A+D で当面留めるかは人間が判断する。

## 9. タスク案

- [ ] `packages/core/src/token-response.ts` の ID Token 発行ブロックに「単一 audience 固定」「`azp` 不付与」の設計コメントを追加（OIDC Core §2 引用付き）
- [ ] 発行 ID Token に対する回帰テスト（`aud === clientId` 文字列、`azp` 不在）を `token-response.test.ts` に追加
- [ ] `study-material/ext-resource-indicators-rfc8707.md` のタスク案に「ID Token への audience 波及方針（`azp` 自動付与）」を追記
- [ ] `idTokenAdditionalAudiences` オプションの導入是非を decision として記録（方針 B 採用時の API シグネチャ案を含む）
- [ ] `alwaysIncludeAzp` オプションの導入是非を decision として記録（方針 C の互換性メリット／デメリット）
- [ ] `validatePayload` の `azp` 検証コードに「発行側は単一 audience 固定だが、`id_token_hint` 等で受信する外部 ID Token は複数 audience を想定」のコメント追加
