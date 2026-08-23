# Claims Languages and Scripts（言語タグ付きクレーム表現, OIDC Core §5.2）

## 1. このトピックで確認したいこと

OIDC Core §5.2 は、人間可読なクレーム（`name`, `family_name`, `address.formatted` など）を **BCP 47 言語タグ付きのメンバー名**（例: `family_name#ja-Kana-JP`, `name#ja`）で複数言語・複数スクリプト提供する仕組みを定義している。本ファイルは、この **応答側（ID Token / UserInfo が返す値）の国際化表現** を OP が扱えるか、扱うべきかを整理する。

これは **要求側パラメータ（`ui_locales` / `claims_locales`）とは別レイヤ**であることに注意する。本トピックは「OP が言語タグ付きクレームをどう返すか」であり、要求側の受理・永続化は既存ファイルが扱う。

> 重複回避:
> - `ui_locales` / `claims_locales` の **受理・AuthTransaction 永続化** は `study-material/done/ui-claims-locales-auth-transaction-handling.md` および `tasks/p3-persist-ui-claims-locales-auth-transaction.md` が扱う。本ファイルは **応答クレームの言語タグ付き表現（§5.2）** に限定し、要求側の説明は繰り返さない。
> - 標準クレームのスコープ→返却（profile/email/address/phone）と fixture 充足は `tasks/done/p1-basic-op-conformance-standard-user-claims.md` を参照。本ファイルは「同じクレームを多言語で返す表現」の差分のみ扱う。

## 2. 関連する仕様・基準

仕様共通索引は `study-material/basic-op-requirement-traceability.md` の §3 を参照。本トピック固有の根拠は以下。

- **OpenID Connect Core 1.0 §5.2 Claims Languages and Scripts** —
  - 人間可読クレームは `クレーム名#言語タグ` 形式のメンバーで複数言語版を併記できる（BCP 47 = RFC 5646）。例:
    ```json
    {
      "name": "Jane Doe",
      "name#ja-Kana-JP": "ジェイン・ドウ",
      "name#ja-Hani-JP": "面田 道緒"
    }
    ```
  - クライアントが `claims_locales` で優先言語を要求でき、OP は可能な範囲で対応する（best-effort）。
  - 言語タグ無しのメンバー（`name`）は「言語不問のデフォルト」。OP は最低限デフォルトを返せばよく、**多言語提供は任意（OPTIONAL）**。
- **OpenID Connect Core 1.0 §5.5.2 Languages and Scripts for Individual Claims** — `claims` パラメータの個別クレーム要求と言語タグの併用（`name#ja` を essential 指定する等）。
- **RFC 5646 / BCP 47 Tags for Identifying Languages** — 言語タグの構文（`ja`, `ja-JP`, `ja-Kana-JP`, `en-US`）。

**Basic OP 認定の必須要件ではない**。Basic OP は言語タグ付きクレームを要求しない。これは **相互運用性・国際化のための拡張トピック**であり、提供は OPTIONAL。本ファイルは「やるべき」結論ではなく **検討段階の判断材料** として置く。

## 3. 参照資料

- OpenID Connect Core 1.0 §5.2 — https://openid.net/specs/openid-connect-core-1_0.html#ClaimsLanguagesAndScripts
- OpenID Connect Core 1.0 §5.5.2 — https://openid.net/specs/openid-connect-core-1_0.html#IndividualClaimsLanguages
- RFC 5646 (BCP 47) — https://www.rfc-editor.org/rfc/rfc5646
- 既存検討（要求側）: `study-material/done/ui-claims-locales-auth-transaction-handling.md`
- 既存検討（標準クレーム返却）: `tasks/done/p1-basic-op-conformance-standard-user-claims.md`

## 4. 現在の実装確認

- **UserInfo / ID Token のクレーム返却**: `packages/core/src/userinfo.ts`
  - `UserClaims` インターフェース（L100 付近〜）は標準クレームを **言語タグ無しの固定キー**（`name?: string`, `family_name?: string`, ...）で定義。`name#ja` のような動的キーは型に存在しない。
  - `filterClaimsByScope`（L214 付近）は `SCOPE_CLAIMS_MAP`（L185 付近）の固定キー集合でフィルタする。`#` 付き派生キーは対象外。
  - `claims` パラメータの個別要求マッチ（`matchesRequestedValue` L302 付近）は値（`value`/`values`）のマッチであり、言語タグ付きクレーム名の解決ロジックは無い。
- **要求側**: `ui_locales` / `claims_locales` は受理・永続化されるが（上記既存ファイル）、その値に基づいて**応答クレームを言語選択する処理は無い**。
- **結論**: 現状は §5.2 の言語タグ付きクレームを **生成も選択もしない**（デフォルト言語のみ返す）。仕様上はデフォルトのみで適合（多言語は OPTIONAL）。

## 5. 現在の実装との差分

- **満たしていること**
  - 言語タグ無しのデフォルトクレームを返しており、§5.2 の「最低限デフォルトを返す」要件は満たす。多言語非提供は仕様違反ではない。
- **不足している可能性があること**
  - 言語タグ付きクレーム（`name#ja-Kana-JP` 等）を store が保持していても、`UserClaims` の固定キー型と `SCOPE_CLAIMS_MAP` の固定集合により **返却経路に乗らない**。
  - `claims_locales` を受け取っても応答言語の選択に使われない（要求と応答が接続されていない）。
- **相互運用性の観点**
  - 多言語ユーザー基盤（日本語の漢字／カナ、CJK の名前表記揺れ等）を検証したい利用者は、現状この OP では §5.2 の挙動を再現できない。
- **Basic OP として提供する上で確認すべきこと**
  - 認定には無関係。提供しない判断でも Basic OP 適合性は損なわれない。

## 6. 改善・追加を検討する理由

- **入れる価値**: 国際化を要件に持つ PoC（多言語名前表記、ローカライズされた address）で、§5.2 の挙動を素早く検証できる。差別化軸の Fidelity に寄与。
- **Basic OP 必須か拡張か**: **拡張（OPTIONAL）**。優先度は低い。
- **導入しやすさ / しにくさ**:
  - しにくい面: `UserClaims` が固定キー型で、`#言語タグ` は動的キー。型・フィルタ・claims マッチの 3 箇所に「言語タグ付きキーの認識」を入れる必要があり、既存の厳密型と相性が悪い。
  - しやすい面: store（resolver）はクレーム集合を返すだけなので、store に多言語値を持たせ、core 側で `claims_locales` に応じて `#タグ` を選択・展開する薄い層を足す形にできる。
- **既存実装との接続**: `filterClaimsByScope` の後段に「言語選択／タグ展開」フィルタを挿入。`claims_locales`（既存の永続化済み値）を入力にする。
- **利用者メリット**: 多言語クレームの検証が可能になる。**実装しない場合のリスク**: 国際化要件の検証ができず、利用者は別 OP（Keycloak 等）に移らざるを得ない。ただし対象ユーザー（PoC 開発者）に国際化要件がどれだけあるかは不明（→ 不明点として明記）。

## 7. 実装方針の候補

最終判断は人間が行う。判断材料のみ。

- **方針 A（最小: デフォルトのみを明文化、非対応を Discovery で正直に）**
  - §5.2 多言語は非対応と決め、`claims_locales_supported` を Discovery に出さない／空にする。ドキュメントで「デフォルト言語のみ」と明記。実装コストほぼゼロ。
- **方針 B（応答側で言語タグ付きクレームを選択・展開）**
  - store に `name#ja` 等を持たせ、core に `claims_locales` ベースの選択層を追加。`UserClaims` を `[claim: string]: unknown` 許容に緩める or 別経路を用意。
  - 長所: §5.2 を実挙動で再現。短所: 型の厳密さが落ちる、フィルタ・claims マッチの整合維持が必要。
- **方針 C（保留）**
  - 対象ユーザーに国際化要件があるかが不明なため、需要が顕在化するまで study-material のまま保留。

## 8. タスク案

> 本トピックは方針未確定（OPTIONAL かつ需要不明）のため、現時点では **タスク化しない**。需要が確認された場合に以下を起票する。

- [ ] （需要確認後）`claims_locales_supported` の Discovery 広告方針を決定（方針 A: 非広告で正直に / 方針 B: 広告して実装）
- [ ] （方針 B 採用時）`UserClaims` 型と `SCOPE_CLAIMS_MAP` を言語タグ付きキーに対応させる設計
- [ ] （方針 B 採用時）`claims_locales` → 応答クレーム言語選択の接続を core に実装し、テストで固定
- [ ] 不明点の解消: 対象ユーザー（PoC 開発者）における §5.2 多言語クレームの需要を調査（`/tech-research` 等）
