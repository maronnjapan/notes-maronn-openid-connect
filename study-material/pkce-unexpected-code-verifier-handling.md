# PKCE バインディングの無い認可コードに対する想定外 code_verifier の取り扱い

## 1. このトピックで確認したいこと

Token Endpoint の authorization_code grant で、**認可コードに PKCE バインディング（`code_challenge`）が無い**場合、リクエストに `code_verifier` が付いていても**完全に無視**して成功応答を返す。
このファイルでは、この「想定外の `code_verifier` を黙って無視する」挙動が

- 仕様上どこまで許容されるか（RFC 7636 / OAuth 2.1）
- 防御的観点（クライアント／フローの取り違え検知）で明示拒否（あるいは少なくとも契約の明文化＋テスト固定）に値するか

を判断材料として整理する。これは **MUST 違反の修正ではなく、ハードニング／契約の明確化**のトピックである。

> 関連既存ファイル（重複記載しない）:
> - `study-material/pkce-code-challenge-format-validation.md` / `tasks/done/p1-pkce-code-challenge-format-validation.md`: `code_challenge` / `code_verifier` の**フォーマット検証**を扱う。
> - `tasks/done/p1-basic-op-pkce-compatibility.md`: Basic OP 認定の non-PKCE code flow との互換（PKCE を任意にする互換モード）を扱う。
> 本ファイルは上記の隙間（**PKCE バインディングが無いコードに `code_verifier` が来たときの挙動契約**）に絞る。

## 2. 関連する仕様・基準

- **RFC 7636 §4.5 / §4.6 (PKCE)**: サーバが `code_challenge` を保存している場合、Token Request の `code_verifier` を検証する。`code_challenge` を持たないコードについて「`code_verifier` が来たら拒否せよ」とは**明記していない**（保存した challenge が無ければ検証しようがない）。したがって無視は仕様違反ではない。
- **OAuth 2.1 draft §4.1.1 / §7.5**: PKCE は全クライアントで REQUIRED。理想的には全ての認可コードが `code_challenge` でバインドされる。本リポジトリは Basic OP 認定（non-PKCE code flow を含む）互換のため、明示的な confidential client + 互換モードでのみ PKCE 無しコードを許容している（`tasks/done/p1-basic-op-pkce-compatibility.md`）。
- **RFC 9700 (OAuth 2.0 Security BCP) §2.1.1**: PKCE による認可コードのバインディングを推奨。バインディングの有無が経路によって曖昧にならないよう、コードと検証手段の対応関係を明確に保つことを推奨。
- **防御的プログラミングの一般原則**: 「サーバが期待していないのにクライアントが送ってきたセキュリティパラメータ」は、フローの取り違え・クライアント設定ミス・攻撃の予兆を示しうる。黙って無視するか明示拒否するかは設計判断だが、**いずれにせよ契約として固定しテストで保証する**ことが望ましい。

仕様上「拒否 MUST」は無い。よって本トピックは「拒否すべきか／無視を明文化すべきか」の**設計判断の整理**である。

## 3. 参照資料

- RFC 7636 Proof Key for Code Exchange by OAuth Public Clients — https://www.rfc-editor.org/rfc/rfc7636 （§4.1〜§4.6: challenge 保存と verifier 検証の手順）
- OAuth 2.1 Authorization Framework (draft-ietf-oauth-v2-1) — https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/ （§4.1.1, §7.5: PKCE REQUIRED）
- RFC 9700 Best Current Practice for OAuth 2.0 Security — https://www.rfc-editor.org/rfc/rfc9700 （§2.1.1: 認可コードのバインディング）

## 4. 現在の実装確認

`packages/core/src/token-request.ts`（authorization_code grant の PKCE 処理）

```ts
// 630-683 行目付近
let codeVerified = false;
const hasPkceBinding =
  authCode.codeChallenge !== undefined ||
  authCode.codeChallengeMethod !== undefined;

if (hasPkceBinding) {
  // code_verifier の存在・長さ・文字種・一致を検証
  ...
  codeVerified = true;
}
// ← hasPkceBinding が false の場合、params.code_verifier が来ていても
//    一切参照せず、検証ブロックをスキップして成功する。
```

- `hasPkceBinding` が `false`（コードに `codeChallenge` も `codeChallengeMethod` も無い）のとき、`params.code_verifier` の有無を一切見ない。
- つまり PKCE 無しで発行されたコードに対し、クライアントが任意の `code_verifier` を付けても、それは黙って捨てられトークンが発行される。
- テスト（`token-request.test.ts:460-475` 付近）には「PKCE 無しコード × `code_verifier` 無し」は存在するが、「**PKCE 無しコード × `code_verifier` あり**」のケースが無い（挙動が未固定）。

## 5. 現在の実装との差分

- **満たしていること**: PKCE バインディングのあるコードに対する `code_verifier` の存在・フォーマット・一致検証は実装済み。PKCE 無しコードを許容する互換モードの方針も明確。
- **仕様上の確認が必要なこと**: RFC 7636 は「challenge の無いコードに verifier が来たら拒否」を要求していない。したがって現状の無視は**仕様違反ではない**。
- **改善した方がよいこと（防御・契約）**:
  - 「PKCE 無しコード × `code_verifier` あり」の挙動が**契約として明文化されておらず、テストでも固定されていない**。将来のリファクタで挙動が静かに変わってもリグレッションとして検知できない。
  - 想定外の `code_verifier` を**明示拒否**するか、**意図的に無視する**かを設計として決め、コメント＋テストで固定すべき。
- **相互運用性**: 正規のクライアントは PKCE を使うコードにのみ verifier を付けるため、明示拒否を入れても実害は小さい。ただし「コードが PKCE 無しで発行されたか」をクライアントが知らずに verifier を送るケースは理論上ありうるため、互換性影響は要評価。

## 6. 改善・追加を検討する理由

- **契約の明確化**: 現在の「黙って無視」は意図的か偶発かが読み取れない。挙動を契約化し、`conformance.test.ts` 相当で固定することで、生成 OP を改変した利用者がこの境界を踏んでも検知できる。
- **取り違え検知**: クライアントが PKCE 前提のフローと非 PKCE フローを取り違えている場合、明示拒否（`invalid_grant`）はその設定ミスを早期に顕在化させる。
- **Basic OP への影響**: Basic OP 認定はこのケースを直接検査しない。よって認定ブロッカーではなく、あくまで設計健全性。**互換モード（non-PKCE）を壊さないこと**が前提条件。
- **導入しやすさ**: 修正は局所的（`hasPkceBinding === false && params.code_verifier !== undefined` の分岐を 1 つ足すか、無視を明記するコメント＋テストを足すだけ）。
- **実装しない場合のリスク**: 挙動が未固定のまま残り、将来の変更で静かにデグレする。セキュリティパラメータの取り扱いが曖昧なまま放置される。

## 7. 実装方針の候補

- **方針 A（明示拒否）**: `hasPkceBinding` が false かつ `params.code_verifier` が存在する場合、`invalid_grant`（または `invalid_request`）で拒否する。理由を「コードは PKCE でバインドされていない」と明示。
  - 利点: 取り違えを早期検知。挙動が明快。
  - 欠点: 理論上、verifier を冗長に付ける正規クライアントを弾く可能性（実害は小さいが要評価）。
- **方針 B（意図的無視を明文化＋テスト固定）**: 現状の無視を維持しつつ、コードにコメントで「PKCE 無しコードでは verifier を無視する」と明記し、「PKCE 無しコード × verifier あり → 成功」のテストを追加して挙動を固定する。
  - 利点: 互換性影響ゼロ。RFC 7636 の「ignore」に忠実。
  - 欠点: 取り違え検知はできない。
- **方針 C（互換モード依存で切り替え）**: PKCE 互換モードが無効（＝全コードが PKCE 必須の運用）なら、そもそも PKCE 無しコードは発行されない前提とし、万一来たら拒否。互換モード有効時のみ無視。

最終的な方針選択は人間が判断する。少なくとも「挙動をテストで固定する」ことは方針に依らず推奨。

## 8. タスク案

- [ ] 「PKCE 無しコード × `code_verifier` あり」を明示拒否するか意図的に無視するかを決定する（方針 A / B / C）。
- [ ] 決定に応じて `token-request.ts` の PKCE 分岐を修正（拒否を入れる）またはコメントで無視を明文化する。
- [ ] `token-request.test.ts` に「PKCE 無しコード × `code_verifier` あり」のケースを追加し、決定した挙動を一意値で固定する。
- [ ] 互換モード（non-PKCE code flow）を壊していないことを既存 PKCE 互換テストで確認する。
- [ ] 生成 OP 側の挙動契約に関わる場合、`packages/cli` のテンプレートと各 sample の `conformance.test.ts` を更新する（CLAUDE.md の契約テスト方針に従う）。
