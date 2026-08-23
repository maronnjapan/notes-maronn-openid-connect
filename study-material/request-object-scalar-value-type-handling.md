# Request Object 内のスカラーパラメータに配列／オブジェクト値が来たときの取り扱い

## 1. このトピックで確認したいこと

signed Request Object（OIDC Core §6）内で、本来スカラー（文字列）であるべきパラメータ（`scope`, `state`, `nonce`, `prompt`, `display`, `max_age`, `acr_values`, `code_challenge`, ...）に **配列やオブジェクトが入っていた場合、現状は黙って無視（drop）し、クエリ側の値へフォールバック**する。

このファイルでは、この「型不一致の値を静かに捨てる」挙動を

- 仕様上どこまで許容されるか
- 明示拒否（`invalid_request`）すべきか、無視を明文化＋テスト固定すべきか

の判断材料として整理する。**MUST 違反の修正ではなく、堅牢性・契約明確化のトピック**である。

> 関連既存ファイル（重複記載しない）:
> - `study-material/request-parameter-hygiene-and-override-contract.md`: 未知パラメータの無視 / 余剰パラメータ / Request Object の **override 意味論**（RO 内 `scope` がクエリ `scope` を supersede する等）を扱う。
> - `study-material/request-object-rejection-and-discovery-honesty.md` / `tasks/done/p1-basic-op-request-object-by-value.md`: Request Object 非対応時の拒否、および by-value 実装を扱う。
> 本ファイルは上記の隙間（**RO 内スカラーパラメータの型不一致値の取り扱い契約**）に絞る。

## 2. 関連する仕様・基準

- **OIDC Core 1.0 §6.1 / §6.3.1 (Request Object)**: Request Object は JWT であり、その claim は Authorization Request パラメータと同じ意味を持つ。各パラメータの構文（スカラー文字列など）は OAuth 2.0 / OIDC のパラメータ定義に従う。`scope`・`prompt`・`acr_values` 等は空白区切りの文字列、`max_age` は数値の文字列表現として定義される。
- §6.3.1 は Request Object 内のパラメータが「同じ意味（same meaning）」を持つことを求めるが、型不一致の claim を**拒否せよ**とは明記していない。したがって無視は仕様違反ではない。
- **RFC 9700 (OAuth 2.0 Security BCP)**: 入力検証の一貫性・厳格性を推奨。構造的に不正な入力を黙って受理（または黙って破棄）するより、明示的に検出する方が堅牢（MUST ではなく設計指針）。

## 3. 参照資料

- OpenID Connect Core 1.0 — https://openid.net/specs/openid-connect-core-1_0.html （§6 Passing Request Parameters as JWTs、§6.3.1 Request Object のパラメータ意味論、§5.5 claims パラメータ）
- RFC 9700 Best Current Practice for OAuth 2.0 Security — https://www.rfc-editor.org/rfc/rfc9700 （入力検証）
- RFC 6749 §3.3（scope 構文）, OIDC Core §3.1.2.1（各パラメータの構文）

## 4. 現在の実装確認

`packages/core/src/authorization-request.ts`（`mergeRequestObjectParams`）

```ts
// 980-989 行目付近
for (const key of REQUEST_OBJECT_OVERRIDE_KEYS) {
  const value = roClaims[key];
  if (value === undefined) continue;
  if (typeof value === 'string') {
    overrides[key] = value;
  } else if (typeof value === 'number' || typeof value === 'boolean') {
    overrides[key] = String(value);
  }
  // Arrays / nested objects are not valid for these scalar parameters; ignore.
}
```

- `value` が配列・オブジェクトの場合、`overrides[key]` に何も入れず、結果としてクエリ側の同名パラメータ（あれば）が有効値となる。
- 例: Request Object に `{"scope": ["openid","profile"]}`（配列）が入っていると、`scope` override は適用されず、クエリに `scope` が無ければ後段で `Missing required parameter: scope` になる（RO に scope を入れたつもりのクライアントには分かりにくいエラー）。
- 数値・真偽値は `String(value)` で文字列化される（`max_age: 300` → `"300"`）。これは妥当。問題は配列・オブジェクトの silent drop。

## 5. 現在の実装との差分

- **満たしていること**: 文字列・数値・真偽値のスカラー値は正しく正規化される。override 意味論は別ファイルで契約化済み。
- **改善した方がよいこと（堅牢性・契約）**:
  - 型不一致（配列／オブジェクト）の値が**黙って捨てられ、誤誘導的なエラー（または別経路の値の採用）になる**。クライアントの設定ミスが検出されにくい。
  - この挙動が**テストで固定されていない**可能性が高い（型不一致 RO のケース）。将来のリファクタで静かに変わりうる。
- **相互運用性**: 正規のクライアントはスカラー値を正しい型で送るため実害は小さい。ただし RO 生成ライブラリのバグ等で型がずれた場合、原因究明が難しいエラーになる。
- **Basic OP 観点**: 認定テストは直接検査しない。設計健全性の改善。

## 6. 改善・追加を検討する理由

- **エラーの分かりやすさ**: 型不一致を `invalid_request` として明示拒否すれば、「RO の `scope` が配列で不正」と原因を直接示せる。silent drop は別の遠いエラーに化ける。
- **契約の固定**: 拒否でも無視でも、テストで挙動を固定することでデグレを防げる。
- **導入しやすさ**: 局所修正（`mergeRequestObjectParams` の else 分岐を追加 or コメント＋テスト追加）。ただし `request` 経路が動くのは Request Object サポート有効時のみで影響範囲は限定的。
- **実装しない場合のリスク**: 型不一致が誤誘導エラーに化け、デバッグコストを生む。挙動が未固定のまま放置される。

## 7. 実装方針の候補

- **方針 A（明示拒否）**: スカラー期待パラメータに配列／オブジェクトが来たら `invalid_request`（リダイレクト可能エラー）で拒否し、どのパラメータが不正かを `error_description` に含める。
- **方針 B（無視を明文化＋テスト固定）**: 現状の silent drop を維持しつつ、コメントとテストで「型不一致は無視しクエリへフォールバック」を契約化する。互換性影響ゼロ。
- **方針 C（部分的拒否）**: セキュリティ critical なパラメータ（`code_challenge`, `max_age`, `prompt`）のみ型不一致を拒否し、それ以外は無視。

最終判断は人間が行う。本トピックは spec の MUST が無いため、まずは「どの方針を採るか」の合意形成が必要（現段階では検討事項）。

## 8. タスク案

> 本トピックは方針未定（拒否 / 無視のいずれを契約とするか未決）のため、現段階ではタスク化せず検討に留める。方針決定後に以下を着手する。

- [ ] スカラーパラメータの型不一致を「拒否」するか「無視（明文化）」するか方針を決定する。
- [ ] 決定に応じて `mergeRequestObjectParams` を修正、またはコメントで挙動を明文化する。
- [ ] 型不一致 RO（配列／オブジェクト値）のテストを追加し挙動を一意に固定する。
- [ ] `request-parameter-hygiene-and-override-contract.md` の override 契約と矛盾しないことを確認する。
