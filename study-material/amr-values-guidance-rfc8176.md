# `amr` クレーム値の標準化ガイド（RFC 8176 Authentication Method Reference Values）

## ステータス

🟢 ガイド / 未着手（実装変更を伴わない可能性が高い）

## 1. このトピックで確認したいこと

ID Token の `amr`（Authentication Methods References）クレームは、エンドユーザーが実際に使用した認証手段の配列を文字列値で表す。`acr`（Authentication Context Class Reference）と並ぶ重要な認証コンテキスト情報だが、

- 値は **OP が自由に決められる文字列**であるため、相互運用性を犠牲にしやすい
- 利用者（PoC 開発者）が `AcrResolver` を実装する際、どのような文字列を入れればよいかの **拠り所が無い**
- 既存実装は `AcrResolver` の注入機構（T-015 done）を提供するだけで、**値そのものに関するガイドラインを提示していない**

RFC 8176 は `amr` の値として頻出する識別子（`pwd`, `otp`, `mfa`, `pop`, `face`, `fpt`, `iris`, `hwk`, `swk`, `sms`, `tel`, `mca`, `mfa`, `pin` 等）を IANA レジストリ化している。本トピックでは、

- 本リポジトリの `AcrResolver` 利用者向けに RFC 8176 の値を案内するドキュメント整備の要否
- core 側で標準値の型定義（TypeScript 補完）を提供するか否か
- Conformance Suite が `amr` 値の標準性をチェックするか

を整理する。本トピックは実装よりも **ドキュメント整備と型サポートの設計判断**が中心。

## 2. 関連する仕様・基準

共通の ID Token / `acr` / `amr` 仕様説明は重複させない。既存ファイルを参照のこと:

- `acr` / `amr` の仕様位置と OIDC Core §2 / §12.1 の挙動: `study-material/basic-op-requirement-traceability.md`
- `AcrResolver` 注入機構: `tasks/done/oidc-improvements-2026-05.md` T-015
- Refresh での `acr` / `amr` 引き継ぎ: 同 T-005

本トピック固有のポイント:

### 2.1 OIDC Core 1.0 §2 の amr 定義

> amr
>   OPTIONAL.  Authentication Methods References. JSON array of strings
>   that are identifiers for authentication methods used in the
>   authentication. ... Parties using this claim will need to agree
>   upon the meanings of the values used, which may be context-specific.
>   The amr value is an array of case sensitive strings.

OIDC Core は値の意味を「当事者間で合意」と委ねており、標準値を強制していない。

### 2.2 RFC 8176 Authentication Method Reference Values

RFC 8176 が定義する代表的な値（IANA レジストリにて拡張可能）:

| 値 | 意味 |
|---|---|
| `pwd` | パスワード |
| `pin` | PIN |
| `otp` | ワンタイムパスワード（OTP） |
| `mfa` | 多要素認証（複合） |
| `mca` | 複数要素ではないが複数チャネル |
| `fpt` | 指紋認証 |
| `face` | 顔認証 |
| `iris` | 虹彩認証 |
| `vbm` | 声紋認証 |
| `geo` | 地理情報 |
| `hwk` | ハードウェアキー所持 |
| `swk` | ソフトウェアキー所持 |
| `sms` | SMS によるチャレンジ確認 |
| `tel` | 電話通話によるチャレンジ確認 |
| `pop` | proof-of-possession（鍵所持証明） |
| `rba` | リスクベース認証 |
| `kba` | 知識ベース認証 |
| `user` | 何らかの形でユーザー個人が確認された |

複数手段の組み合わせは配列で表現する（例: `["pwd", "otp", "mfa"]`）。

### 2.3 Conformance との関係

OIDC Basic OP の Conformance テストは `amr` クレームを発行する場合の**形式**（配列・文字列要素）を検証するが、**値の標準性**（RFC 8176 準拠か）は基本的には検査対象外。ただし将来の FAPI / vectors-of-trust 系プロファイルでは `amr` 値の標準性が前提となる場合がある。

## 3. 参照資料

- RFC 8176 — https://www.rfc-editor.org/rfc/rfc8176
- IANA AMR Values Registry — https://www.iana.org/assignments/authentication-method-reference-values/authentication-method-reference-values.xhtml
- OIDC Core 1.0 §2 — https://openid.net/specs/openid-connect-core-1_0.html#IDToken （amr の仕様）
- OIDC Core 1.0 §5.1 — claim 形式

## 4. 現在の実装確認

- `packages/core/src/token-response.ts`: `AcrResolver` が `{ acr: string; amr: string[] } | undefined` を返す型。値の中身は呼び出し側自由。
- `packages/core/src/token-request.ts`: refresh_token grant 時、`RefreshTokenInfo.amr` を引き継ぐ（OIDC Core §12.1 SHOULD 準拠）。
- `packages/core/src/id-token.ts`: ID Token に `amr` を含める処理は `IdTokenPayload.amr?: string[]` として開いており、値の中身は検証しない。
- `packages/sample/src/oidc-provider/apply.ts`: `acrResolver` を受け取って context に注入する。sample は resolver の参考実装を提供していない（利用者責務）。
- ドキュメント: CLAUDE.md・各 README に RFC 8176 への参照無し。

## 5. 現在の実装との差分

満たしていること:

- `amr` を ID Token に正しく含められる（配列・case sensitive 文字列）。
- refresh で初回認証時の `amr` を引き継ぐ仕様要件（§12.1）を満たす。
- `AcrResolver` 注入により、host application が認証手段に応じて柔軟に値を決められる。

不足／改善余地:

- 🟢 **RFC 8176 への案内が無い**: 利用者が独自に `["password"]` `["password-otp"]` のような非標準値を入れがちで、相互運用性が落ちる。RFC 8176 の標準値を案内する README / コメントが欲しい。
- 🟢 **TypeScript 型補完での助け舟が無い**: `amr: string[]` のみで、補完が効かない。RFC 8176 値のリテラル合併型（任意拡張可能な形）を export すれば、ライブラリ利用時に「何を入れるか」が IDE 上で見える。
- 🟢 **sample の `AcrResolver` 参考実装が無い**: T-015 は注入機構を提供したが、典型値（`pwd` / `mfa` 等）の例示が無いため、利用者が「何を返せばよいか」の参考になりにくい。
- 🟢 **Discovery `acr_values_supported` との接続**: OP が広告する `acr_values_supported` と `AcrResolver` が返す `acr` 値は整合させるべきだが、現状ガイドが無い。本論点は `study-material/discovery-optional-metadata-fields.md` 側でも触れる予定。

セキュリティ観点:

- `amr` 値そのものはセキュリティに直接影響しない（RP 側で要件と突合する用途）。
- ただし誤った `amr` を返すと、RP が「MFA 済み」と誤判断する可能性がある（例: パスワード単独なのに `mfa` を返してしまう）。`AcrResolver` 実装ガイドで「実際の認証手段と一致させる」注意喚起が必要。

## 6. 改善・追加を検討する理由

価値:

- 利用者（PoC 開発者）の混乱を減らす。`AcrResolver` を実装する際の「何の値を入れるか」を即決できる。
- 「Fidelity（仕様準拠）」のシグナル: 標準値を提示する OSS は信頼性が上がる。
- 将来の拡張（vectors-of-trust、FAPI、Step-up Authentication など）への基礎準備。
- 実装コスト極小: ドキュメント追加・型 export のみで完結。

導入難易度:

- 🟢 **極小**: コード変更はオプション（型 export のみ）。`packages/core/src/index.ts` に型を export し、`packages/sample` に参考 `AcrResolver` を例示する程度。
- 既存の `AcrResolver` インタフェースを変更しないため後方互換。

実装しない場合のリスク:

- 利用者が独自値（`["password"]` など）を入れて、相互運用性が落ちる。
- 将来 FAPI 等の拡張に進む際、`amr` の値設計を後付け修正する必要が出る。

## 7. 実装方針の候補

### 方針A（ドキュメント整備のみ）

- `packages/core/src/token-response.ts` の `AcrResolver` 型コメントに RFC 8176 リンクと代表値を併記。
- README.md / CLAUDE.md に `amr` 値のガイドへの参照を追加。
- 実装コード変更ゼロ。

### 方針B（A + 型サポート）

- `packages/core/src/index.ts` に RFC 8176 標準値のリテラル合併型を export:

  ```typescript
  export type StandardAmrValue =
    | 'pwd' | 'pin' | 'otp' | 'mfa' | 'mca'
    | 'fpt' | 'face' | 'iris' | 'vbm'
    | 'geo' | 'hwk' | 'swk' | 'sms' | 'tel'
    | 'pop' | 'rba' | 'kba' | 'user';

  // 拡張可能: 利用者は (StandardAmrValue | string)[] で受けられる
  ```

- `AcrResolver` の戻り値型は変えない（後方互換のため `string[]` のまま）。型は補完用途。

### 方針C（A + sample 参考実装）

- `packages/sample/src/oidc-provider/resolvers.ts` に「最低限のパスワード認証 → `amr: ['pwd']`」「OTP 加算 → `amr: ['pwd', 'otp', 'mfa']`」といった参考 `AcrResolver` を追加（コメントアウト or `// eslint-disable` で配置）。
- 利用者がコードから直接コピーできる例を提供。

### 方針D（A + B + C 全実施）

- ドキュメント・型・参考実装を一式追加。最も親切だが、コア仕様外なので「ガイドの厚さ」と「PoC 用 OSS の軽さ」のトレードオフを判断要。

## 8. タスク案

- [ ] 方針 A / B / C / D を選択（人間が判断）
- [ ] （方針 A 採用時）`AcrResolver` 型コメントに RFC 8176 リンクと代表値の表を追記
- [ ] （方針 B 採用時）`StandardAmrValue` リテラル合併型を export
- [ ] （方針 C 採用時）`packages/sample/src/oidc-provider/resolvers.ts` 等に参考 `AcrResolver` 実装を追加
- [ ] テスト: 参考実装が想定通り `amr` 配列を返すこと（方針 C 採用時）
- [ ] `study-material/discovery-optional-metadata-fields.md` の `acr_values_supported` セクションと相互参照
