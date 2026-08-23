# AMR Values（RFC 8176）と AcrResolver 実装ガイドの整備

## ステータス

🟡 Minor（相互運用性 / 利用者向けドキュメント）/ 未着手

## 1. このトピックで確認したいこと

ID Token の `amr` クレーム（Authentication Methods References）は OP の認証方法を表す **文字列配列**。本リポジトリは `AcrResolver` で `amr` を返す I/F を持ち、Refresh Token 経由でも初回値を保持する（`tasks/done/p0-refresh-acr-amr-persistence.md`、`tasks/done/T-020-refresh-scope-claims-filter.md`）。

しかし:

- `amr` に入れる **標準化された値**（RFC 8176 IANA レジストリ）が存在することが OSS 利用者に伝わっていない
- `AcrResolver` 実装ガイドに「独自文字列ではなく IANA 登録値を返すと相互運用性が高まる」旨が無い

このファイルは **RFC 8176 の値レジストリ**を `AcrResolver` 実装者に伝える文書整備を扱う。実装コードの変更は不要なケースが多いが、ドキュメント追記とサンプルコード差分はあり得る。

## 2. 関連する仕様・基準

### 2.1 RFC 8176 Authentication Method Reference Values

- `amr` クレーム値の標準化レジストリ。IANA に登録されている主な値:
  - `pwd`: パスワード認証
  - `otp`: One-Time Password（TOTP/HOTP）
  - `mfa`: 複数要素認証一般（複合的）
  - `sms`: SMS OTP
  - `tel`: 電話 OTP（音声）
  - `mca`: Multiple-Channel Authentication（複数チャネル）
  - `face`: 顔認証
  - `fpt`: 指紋認証
  - `iris`: 虹彩認証
  - `geo`: 位置情報併用
  - `hwk`: ハードウェアトークン
  - `swk`: ソフトウェアトークン
  - `kba`: 知識ベース認証（KBA / 秘密の質問）
  - `pin`: PIN
  - `rba`: リスクベース認証
  - `sc`: スマートカード
  - `user`: ユーザーがアクション（同意を含む）
  - `wia`: Windows Integrated Authentication
- 値は **複数組み合わせ可**（例: `["pwd", "otp"]` = パスワード + OTP）。
- 仕様は **クライアント側で `amr` を信頼判定に使う**ことを許容するため、OP は実際の認証手段に対応する標準値を返すべき。

### 2.2 OIDC Core との関係

- OIDC Core §2: `amr` は OPTIONAL クレームで配列、OP の認証ポリシーに依存し、値の意味は仕様外。
- RFC 8176 は OIDC Core の `amr` の **値レジストリ**を提供する仕様（IANA Authentication Method Reference Values Registry）。

### 2.3 `acr` との関係

- `acr` は単一文字列で「保証レベル全体の名前」を表す（NIST SP 800-63 の `urn:mace:incommon:iap:silver` 等）。
- `amr` は「保証レベルを構成する個別認証要素の集合」。`acr=ial2` の根拠が `amr=["pwd","otp"]` のような対応。
- 両者を返すかは OP 裁量。

## 3. 参照資料

- RFC 8176 — Authentication Method Reference Values: https://www.rfc-editor.org/rfc/rfc8176
  - §2 AMR Values（主要値定義）
  - §3 Security Considerations
  - §4 IANA Considerations（レジストリ運用ルール）
- IANA Authentication Method Reference Values: https://www.iana.org/assignments/authentication-method-reference-values/authentication-method-reference-values.xhtml
- OIDC Core 1.0 §2（`amr` クレーム）: https://openid.net/specs/openid-connect-core-1_0.html
- 関連: `tasks/done/T-015-acr-amr-resolver.md`、`packages/core/src/token-response.ts`（`AcrResolver` 定義）

## 4. 現在の実装確認

- `AcrResolver` 型: `packages/core/src/token-response.ts:24-28`
  ```typescript
  export type AcrResolver = (context: {
    userId: string;
    clientId: string;
    requestedAcrValues?: string;
  }) => Promise<{ acr: string; amr: string[] } | undefined>;
  ```
- 値の検証は無い（任意文字列を受け入れる設計、`amr` 配列も型上のみ）。これは仕様準拠（RFC 8176 §2 は「使う値は OP/RP 合意で定義」）と整合。
- `tasks/done/T-015-acr-amr-resolver.md` で resolver の I/F は確定済み。
- ドキュメント / サンプル実装に **RFC 8176 標準値の提示が無い**。CLI が生成するサンプルコード（`packages/cli/src/frameworks/hono/templates.ts`）の resolver 例は `undefined` 返却または独自値のみ。

## 5. 現在の実装との差分

- **満たしていること**: `amr` を配列で返す I/F、Refresh で初回値を保持する経路、`acr` と独立して返せる柔軟性。
- **不足している可能性があること**
  - 利用者向けドキュメント / コメント / 型定義 JSDoc 内に **「RFC 8176 の標準値を返すと相互運用性が高い」** 旨が無い。
  - `AcrResolver` 型に標準値の **string literal union 型ヒント**を任意で提供できないか（例: `type Rfc8176AmrValue = 'pwd' | 'otp' | 'mfa' | ...`）。strict にすると拡張性を阻害するが、ヒント目的の参考型として export する案はあり得る。
  - CLI 生成サンプルが「実装者向けスケルトン」を返すだけで、`pwd` 単体や `pwd,mfa` のような **教育的例**を出していない。
- **Discovery 観点**
  - `amr_values_supported` というメタデータは公式仕様には無い（IANA Authorization Server Metadata Registry にも未登録）。広告する慣行も標準化されていないため、ここでは推奨しない。
  - `acr_values_supported` は標準メタデータあり（`study-material/ext-step-up-authentication-rfc9470.md` で扱う）。

## 6. 改善・追加を検討する理由

- 本リポジトリの利用者（PoC 開発者）にとって、`amr` に何を入れるべきかは仕様だけからは見えにくい。RFC 8176 を案内するだけで実装品質が顕著に上がる。
- 実装コードを変えなくても **JSDoc とサンプル修正だけ**で改善できるため、コストは小。
- 実装しない場合の制約: 各利用者が独自値を入れた結果、RP が `amr` を信頼判定に使えなくなる（独自値の意味を OP ごとに学習する必要あり）。
- `ext-step-up-authentication-rfc9470.md` で扱う Step-up loop でも、AT/ID Token の `amr` が標準値であるほど RP/RS 側ロジックがシンプルになる。

## 7. 実装方針の候補

### 方針A（推奨・最小コスト）: ドキュメント + JSDoc 充実

- `AcrResolver` 型の JSDoc に「`amr` は RFC 8176 の IANA 登録値を返すのが推奨」と追記。
- CLI が生成する resolver スケルトンに、コメントで RFC 8176 主要値の表を入れる。
- `resolver-and-store-contract.md` に AcrResolver セクションを追記（既存ファイルへの追記、新規ファイルではない）。
- 追加実装コードなし。テスト追加もなし。

### 方針B（中程度）: 型ヒント export

- `Rfc8176AmrValue` を string literal union 型として export し、`AcrResolver` の戻り型を `amr?: (Rfc8176AmrValue | string)[]` のような形に整える（拡張性は維持）。
- 強制力は無いが、TypeScript 利用者の補完で標準値が見えるようになる。

### 方針C: バリデーション関数の提供

- `validateAmrValues(amr: string[]): { standard: string[]; nonStandard: string[] }` のような検査関数を core に追加。利用者が任意で呼べる。
- 強制ではなく診断目的。

## 8. タスク案

- [ ] 方針A/B/C を選択する（ユーザー判断）。方針A は単独で完了可能、B/C は A の上に積み上げ
- [ ] 方針A: `AcrResolver` JSDoc に RFC 8176 リンクと主要値リストを追記
- [ ] 方針A: CLI が生成する resolver スケルトンに RFC 8176 標準値コメント／例を入れる
- [ ] 方針A: `resolver-and-store-contract.md` に AcrResolver セクション追記（重複は既存ファイルへ追記、新規作成しない）
- [ ] 方針B 採用時: `Rfc8176AmrValue` 型を `packages/core/src/index.ts` から export
- [ ] 方針C 採用時: `validateAmrValues` 関数のテスト先行作成 → 実装
- [ ] 完了条件: ドキュメント変更が pnpm lint/format を通過、CLI テストで生成サンプルが新しいコメントを含むこと
