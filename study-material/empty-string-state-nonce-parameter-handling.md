# 空文字列の `state` / `nonce` を「値あり」として保存・echo している問題

## ステータス

🟢 Low / 未着手

## 1. このトピックで確認したいこと

認可リクエストで `state=`（空文字列）や `nonce=`（空文字列）が来た場合、実装は `!== undefined` でのみ
存在判定するため、空文字列を「値あり」として扱い、認可レスポンス／エラーレスポンスに `state=`（空）を
そのまま echo し、ID Token に `nonce: ""` を格納する。空の `state` は CSRF 保護の意味を持たず、
空 `nonce` はリプレイ保護の意味を持たない。「空文字列を送る」ことと「パラメータを省略する」ことの
プロトコル上の差が観測可能な形で残り、テストでも固定されていない。

本ファイルは、空文字列の `state` / `nonce` を「省略」と同一視すべきか、それとも現状どおり保持すべきかを
整理し、挙動をテストで固定することを検討する。

> 関連既存ファイル（重複回避）：
> - `study-material/done/state-roundtrip-echo-invariant.md` / `tasks/done/p3-state-roundtrip-echo-invariant.md`:
>   `state` を「非空で存在」か「完全に不在」かの二択で echo/非 echo の不変条件を扱う。
>   **空文字列という第三の状態**は扱っていない。
> - `study-material/id-token-nonce-binding-and-replay.md`: `nonce` のバインド／リプレイを扱うが、
>   **空文字列 nonce の扱い**は対象外。
> 本ファイル固有の論点は「**空文字列 `state`/`nonce` を省略と同一視するか、境界をテスト固定する**」こと。

## 2. 関連する仕様・基準

- **RFC 6749 §4.1.1（`state`）**: `state` は「クライアントが送った値をそのまま返す」CSRF 対策パラメータ。
  空文字列は照合上意味を持たない（攻撃者も空を送れるため CSRF 保護にならない）。
- **OpenID Connect Core 1.0 §3.1.2.1（`nonce`）**: `nonce` は ID Token に格納され、クライアントが
  リプレイ検出に用いる。空 `nonce` は一意性・結びつけの意味を持たない。
- **パラメータの「存在」判定**: 仕様は「省略」と「空文字列」を厳密に区別していない箇所が多いが、
  セキュリティ的に無意味な空値を「値あり」として ID Token に格納・レスポンスに echo するのは、
  相互運用性・観測可能性の観点で望ましくない（省略と同一視する実装が一般的）。

## 3. 参照資料

- RFC 6749 §4.1.1（Authorization Request, `state`）: https://www.rfc-editor.org/rfc/rfc6749#section-4.1.1
- OpenID Connect Core 1.0 §3.1.2.1（`nonce`）: https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest
- OpenID Connect Core 1.0 §15.5.2（nonce の実装ノート）: https://openid.net/specs/openid-connect-core-1_0.html#NonceNotes

## 4. 現在の実装確認

- `packages/core/src/authorization-request.ts`
  - `state` / `nonce` は `effective.state` / `effective.nonce`（Request Object マージ後の実効値）から取得し、
    `!== undefined` のガードのみで保存される（`:768`, `:937`, `:969` 付近）。空文字列は `'' !== undefined` で保持される。
- `packages/core/src/auth-transaction.ts`
  - トランザクションへの保存（`:213-217` 付近）と `completeAuthTransaction`（`:468` 付近）で
    `state !== undefined` のみを見て result に格納するため、空 `state` はレスポンスに `state=`（空）として echo される。
  - `nonce` も同様に空文字列が保持され、ID Token 生成時に `nonce: ""` として載りうる。

## 5. 現在の実装との差分

- **満たしていること**
  - 非空 `state`/`nonce` のラウンドトリップ・バインドは正しく機能する。
- **不足している可能性があること**
  - 空文字列 `state`/`nonce` を「省略」と同一視するか否かが未定義・未テスト。
- **セキュリティ上の観点**
  - 空 `state` は CSRF 保護にならず、空 `nonce` はリプレイ保護にならない。これらを「値あり」として扱うと、
    RP 側が「state/nonce が設定されている」と誤認する余地がある（実害は限定的だが望ましくない）。
- **相互運用性**
  - 「空を送る」と「省略」の観測差（レスポンスに `state=` が付く／ID Token に `nonce:""` が載る）が残る。

## 6. 改善・追加を検討する理由

- **明確性 / Fidelity**: 空値を省略と同一視する挙動を明文化・テスト固定すると、境界の解釈が定まる。
- **導入しやすさ**: `state`/`nonce` の取得箇所で `value && value.length > 0` に条件を寄せるだけ（または
  空文字列を `undefined` に正規化する 1 箇所の正規化）で済む。実装変更は小さい。
- **実装しない場合のリスク**: 空値の扱いが未定義のまま、将来のリファクタで挙動が静かに変わる。
  RP が空 `nonce` を「設定済み」と誤解する余地が残る。
- 優先度は低い（Low）。実害は限定的で、主に「境界の明確化とテスト固定」が目的。

## 7. 実装方針の候補

判断材料の整理（最終判断は人間）。

- 方針A（推奨）: 空文字列の `state`/`nonce` を**省略と同一視**（`undefined` に正規化）する。
  - レスポンスに空 `state` を付けず、ID Token に空 `nonce` を載せない。境界が明確になる。
- 方針B: 現状（空を保持）を正式挙動とし、テストで固定するのみ。
  - 実装変更なし。ただし「空 state/nonce をどう返すか」を明示的にドキュメント化する。
- どちらでも、Request Object マージ後の実効値に対して一貫して適用すること（query と Request Object の
  両経路で挙動を揃える）。

## 8. タスク案

- [ ] 方針を決定（省略同一視 / 現状固定）
- [ ] `authorization-request.test.ts` に先行テスト:
  - [ ] `state=`（空）送信時、認可レスポンス／エラーレスポンスに `state` が付かない（方針A）または空で付く（方針B）
  - [ ] `nonce=`（空）送信時、ID Token に `nonce` が載らない（方針A）または空で載る（方針B）
- [ ] 方針A の場合、`state`/`nonce` の取得箇所で空文字列を `undefined` に正規化
- [ ] 生成 OP の挙動が変わる場合は `packages/cli` テンプレートと sample の `conformance.test.ts` を更新
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test` がパス
