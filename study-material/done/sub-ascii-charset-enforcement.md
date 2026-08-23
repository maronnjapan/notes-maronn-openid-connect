# `sub` クレームの ASCII 文字種・バイト長検証（255 ASCII 制約の正確な実装）

## ステータス

🟡 Medium / 未着手（ドキュメント不正確の是正を含む）

## 1. タイトル

ID Token / UserInfo で発行する `sub`（Subject Identifier）が OIDC Core §2 の「255 ASCII 文字以内」制約を**正確に**満たしているかを確認し、現状の長さチェックが ASCII 文字種・バイト長を見ていない差分と、既存 study-material の「ASCII 検証済み」という不正確な記述を是正する。

## 2. このトピックで確認したいこと

- `generateIdToken` / ID Token 発行経路の `sub` バリデーションが、OIDC Core §2 が言う **255 ASCII characters** を満たしているか
- 現状の `payload.sub.length > 255`（UTF-16 コードユニット数）チェックでは、(a) 非 ASCII 文字を含む `sub` を素通しする、(b) UTF-16 length と UTF-8 バイト長の乖離により「255 ASCII を超えるが length は 255 以下」のケースを取りこぼす、という 2 点の差分があるかを確認する
- 既存の `study-material/sub-stability-and-subject-types.md` および `study-material/pairwise-subject-identifier.md` が「ASCII の構造検証は実装済み」と記載しているが、実装は文字種チェックを持たない。**ドキュメントと実装の乖離**を是正対象として明記する

> 注: `sub` の安定性・subject_types（public/pairwise）の整合は `study-material/sub-stability-and-subject-types.md` / `study-material/pairwise-subject-identifier.md` で扱う。本ファイルは**文字種・長さの構文検証**という直交する差分のみを扱い、安定性論点は繰り返さない。

## 3. 関連する仕様・基準

- **OpenID Connect Core 1.0 §2（ID Token / Subject Identifier）**: Subject Identifier は「A locally unique and never reassigned identifier within the Issuer for the End-User, which is intended to be consumed by the Client. ... It MUST NOT exceed 255 ASCII characters in length.」と定義される。ここでの 255 は **ASCII 文字数**であり、暗黙に「ASCII の範囲内であること」を前提にした制約である。
- **OpenID Connect Core 1.0 §8.1（Pairwise Identifier Algorithm）/ §5.1**: `sub` は文字列クレーム。pairwise の場合も最終的に文字列として 255 ASCII 制約に従う。
- **RFC 7519 §2 / §4**: JWT のクレーム値は JSON 文字列。JSON 自体は Unicode を許容するため、「255 ASCII」制約は JWT 層ではなく OIDC 層の追加制約である点に注意。
- **補足（なぜ ASCII か）**: `sub` は他システムのキー・URL パス・ログ等で広く再利用される。非 ASCII を許すと正規化・エンコーディングの相互運用性問題（NFC/NFD の揺れ、URL エンコード差異、ログの文字化け）を招くため、仕様は ASCII に限定している。

## 4. 参照資料

- OpenID Connect Core 1.0 §2 「ID Token」/ Subject Identifier 定義 — https://openid.net/specs/openid-connect-core-1_0.html#IDToken （"It MUST NOT exceed 255 ASCII characters in length."）
- OpenID Connect Core 1.0 §8 「Subject Identifier Types」 — https://openid.net/specs/openid-connect-core-1_0.html#SubjectIDTypes
- RFC 7519 §4.1 「Registered Claim Names」 — https://www.rfc-editor.org/rfc/rfc7519#section-4.1
- 関連既存ファイル（安定性・subject_types 論点）: `study-material/sub-stability-and-subject-types.md`、`study-material/pairwise-subject-identifier.md`

## 5. 現在の実装確認

- `packages/core/src/id-token.ts`（`validateIdTokenPayload` 相当、行 96-103）:
  ```ts
  if (!payload.sub) {
    throw new Error('Missing required claim: sub');
  }

  // OIDC Core 1.0 Section 5.1: sub must not exceed 255 ASCII characters
  if (payload.sub.length > 255) {
    throw new Error('Subject identifier must not exceed 255 ASCII characters');
  }
  ```
  - `payload.sub.length` は **UTF-16 コードユニット数**であり、ASCII 文字数とは一致しない。
  - ファイル全体に `charCodeAt` / `0x7f` / `[\x00-\x7F]` 等の **ASCII 範囲判定が一切存在しない**（grep で該当なし）。
- 既存ドキュメントの不正確な記述:
  - `study-material/sub-stability-and-subject-types.md`（該当行）: 「`sub` の存在・255文字以内・**ASCII** の構造検証はある」
  - `study-material/pairwise-subject-identifier.md`（該当行）: 「`sub` の構造的バリデーション（**255 ASCII**）は実装済み」
  - いずれも「ASCII 検証済み」と読めるが、実装は長さチェックのみ。

## 6. 現在の実装との差分

満たしていること:

- `sub` の存在チェックは実装済み。
- 「長さ 255 以下」のおおまかな上限は機能する（ASCII 純粋なら正しく働く）。

不足している可能性があること:

- 🟡 **ASCII 文字種を検証していない**: `sub = "ユーザー識別子😀"` のような非 ASCII を含む `sub` が発行できてしまう。OIDC Core §2 の「ASCII characters」制約に反する。
- 🟡 **長さの数え方が ASCII 文字数ではない**: 絵文字（サロゲートペア）や合成文字を含むと `String.prototype.length` は ASCII 文字数からずれる。「255 ASCII を超えるが `.length <= 255`」または逆のケースで判定がブレる。純 ASCII の OP では実害が出にくいため見落とされやすい。
- 🟡 **発行側（generate）と検証側（`validateIdTokenHint`）の非対称**: 本リポジトリは「発行側でも検証側と同じ厳格さを持たせる」方針（`exp`/`iat` の NumericDate 検証、`aud` メンバー検証で実施済み）を採っている。`sub` の文字種だけがこの方針から漏れている。
- 🟢 **ドキュメント不正確**: 2 つの study-material が「ASCII 検証済み」と記載しており、実装と乖離。レビュー者が「対応済み」と誤認するリスク。

Basic OP 認定との関係:

- Basic OP Conformance テストは通常 `sub` を OP が生成するため、純 ASCII であれば認定上の直接のブロッカーにはなりにくい。本論点は **Fidelity（仕様忠実性）/ 相互運用性 / ドキュメント正確性**の軸。

## 7. 改善・追加を検討する理由

- 「最新の OIDC/OAuth 仕様を忠実に」を掲げる本 OSS にとって、§2 の MUST 級の構文制約（255 ASCII）を**長さしか見ていない**のは Fidelity シグナルの毀損。
- 利用者（PoC 開発者）が `UserClaimsResolver` / 認可コード発行時に DB の生 ID（日本語名・絵文字を含む可能性）を `sub` にそのまま流用するのは「ありがちな実装ミス」。OP 側が早期に弾けば、相互運用性問題（RP 側の `sub` 比較失敗・URL エンコード崩れ）を未然に防げる。
- 既存方針（発行側でも厳格検証）と整合し、導入は局所的。
- 実装しない場合のリスク: 非 ASCII `sub` を発行する OP を生成でき、RP との相互運用で `sub` 不一致・正規化バグが発生。かつドキュメントが「対応済み」と誤誘導し続ける。

拡張か必須か:

- **Basic OP 必須ではない**が、§2 の MUST に対する忠実性の問題であり「準拠を謳う上で確認すべき」項目。優先度は中。

## 8. 実装方針の候補

### 方針A（ASCII 文字種 + 長さを同時に検証, 推奨検討筆頭）

- `id-token.ts` の `sub` 検証を以下に置換:
  ```ts
  // OIDC Core 1.0 §2: sub MUST NOT exceed 255 ASCII characters.
  // ASCII 範囲外（U+0080 以上）を含む場合と、255 文字を超える場合の両方を拒否する。
  if (!/^[\x21-\x7E]{1,255}$/.test(payload.sub)) {
    throw new Error(
      'Subject identifier must be 1-255 printable ASCII characters'
    );
  }
  ```
  - 制御文字・空白を許すか（`\x20`〜）は要判断。`sub` に空白・制御文字を入れる正当な理由は乏しいため、印字可能 ASCII（`\x21-\x7E`）に限定する案を筆頭に置く。ただし既存利用者の `sub` を壊さないよう、緩める場合は `\x20-\x7E` も選択肢。
- 検証側（`validateIdTokenHint`）にも同等チェックを足し、発行・検証の対称性を維持。

### 方針B（文字種は warn、長さのみ厳格 / 後方互換重視）

- 既存利用者が非 ASCII `sub` を出している可能性を考慮し、いきなり throw せず「長さは throw・文字種はオプトインで throw（デフォルト warn ログ）」とする。
- PoC ツールという性質上、明確に弾く方が学びになるため、方針 A を推す。最終判断は人間。

### 方針C（ドキュメント是正のみ先行）

- まず `sub-stability-and-subject-types.md` / `pairwise-subject-identifier.md` の「ASCII 検証済み」記述を「長さのみ検証・文字種は未検証」に是正し、実装は後続。最小・即時にできる。

判断材料:

- 文字数カウントの厳密さ（サロゲートペアを 1 文字と数えるか）は、正規表現 `[\x21-\x7E]` を使えば「ASCII 以外を含む時点で reject」されるため自然に解決する（ASCII のみなら `.length` == 文字数 == バイト数）。
- バイト長で数えるか文字数で数えるかは、ASCII に限定すれば一致するため論点が消える。これが方針 A の利点。

## 9. タスク案

- [ ] 方針（A/B/C）を決定（人間が判断）
- [ ] （TDD）`id-token.test.ts` に以下のケースを先に追加:
  - 純 ASCII 255 文字 → 発行成功
  - 純 ASCII 256 文字 → 拒否
  - 非 ASCII を 1 文字含む（例 `"abcあ"`）→ 拒否
  - 絵文字（サロゲートペア）を含む → 拒否
  - 印字不可制御文字（`\x00`, `\n`）を含む → 拒否（方針 A 採用時）
- [ ] `id-token.ts` の `sub` 検証を ASCII 文字種 + 長さ検証に置換
- [ ] `validateIdTokenHint`（検証側）にも対称的に適用するか判断・実装
- [ ] `study-material/sub-stability-and-subject-types.md` の「ASCII の構造検証はある」記述を実装実態に合わせて是正
- [ ] `study-material/pairwise-subject-identifier.md` の「255 ASCII は実装済み」記述を是正
- [ ] 署名付き UserInfo / JWT Access Token の `sub` も同経路で発行されるか確認し、必要なら共通バリデータに切り出す
