# `max_age=0` の再認証強制が同一秒境界で破れる（`requiresReauthentication` の境界演算子）

## ステータス

🟠 High / 未着手

## 1. このトピックで確認したいこと

OIDC Core §3.1.2.1 の `max_age` は「最後の認証からの許容経過秒数」であり、`max_age=0` は
「End-User を**必ず**アクティブに再認証させる」（実質 `prompt=login` 相当のフレッシュネス要求）を意味する。
現在の `requiresReauthentication(maxAge, authTime)` は `now - authTime > maxAge` で判定しており、
`maxAge=0` かつ `authTime === now`（ログイン直後、同一の壁時計秒内での認可）だと `0 > 0` が `false` となり、
**再認証が要求されない**。実装のドキュメントコメントは「0 は常に再認証を強制」と書いており、コードと矛盾している。

本ファイルは、この `max_age=0` の同一秒境界バグを整理し、`max_age=0` を確実に再認証強制へ写像する
判定条件を検討する。

> 関連既存ファイル：
> - `tasks/done/04-max-age-enforcement.md` は `max_age` の一般的な enforcement（経過時間による再認証要求）を扱うが、
>   **`max_age=0` の同一秒境界**という具体的な演算子バグは扱っていない。
> - `study-material/done/client-default-max-age-and-require-auth-time.md` はクライアント既定 `default_max_age` と
>   `require_auth_time` を扱い、本トピックの境界条件とは別。
> 本ファイルは **`requiresReauthentication` の境界演算子が `max_age=0` の MUST を満たさない**固有差分のみを扱う。

## 2. 関連する仕様・基準

- **OpenID Connect Core 1.0 §3.1.2.1（Authentication Request, `max_age`）**:
  > Maximum Authentication Age. ... If the elapsed time is greater than this value, the OP MUST attempt to
  > actively re-authenticate the End-User.
  - `max_age=0` は「経過時間がゼロを超えたら再認証」＝実質「必ず再認証」を意図する。多くの OP は
    `max_age=0` を `prompt=login` と同等に扱う。
- **§3.1.2.1 の `auth_time` との関係**: `max_age` を送ると ID Token の `auth_time` が必須化される。
  `auth_time` は秒精度の NumericDate であり、判定も秒精度で行われる前提。
- **秒精度の含意**: 判定を秒に丸める以上、「経過 0 秒（同一秒内）」を「再認証不要」と扱うと `max_age=0` の
  MUST（必ず再認証）が同一秒内で破れる。`max_age=0` は経過秒数の大小比較ではなく「フレッシュな認証を要求する」
  意味として特別扱いする必要がある。

## 3. 参照資料

- OpenID Connect Core 1.0 §3.1.2.1（Authentication Request）: https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest
- OpenID Connect Core 1.0 §2（`auth_time` Claim）: https://openid.net/specs/openid-connect-core-1_0.html#IDToken

## 4. 現在の実装確認

- `packages/core/src/auth-transaction.ts`
  - `requiresReauthentication`（`:435-438` 付近）:
    ```ts
    export function requiresReauthentication(maxAge: number, authTime: number): boolean {
      const now = Math.floor(Date.now() / 1000);
      return now - authTime > maxAge;
    }
    ```
  - ドキュメントコメント（`:431` 付近）は「maxAge 最大認証経過秒数（0 は常に再認証を強制）」と記載。
    しかしコードは `> maxAge`（strict greater-than）であり、`maxAge=0`・`authTime===now` で `0 > 0 === false`。
- 呼び出し側（prompt/max_age 判定を行う認可フロー）はこの戻り値をもとに再認証要否を決めるため、
  同一秒内のケースで `max_age=0` が無視される。

## 5. 現在の実装との差分

- **満たしていること**
  - `max_age > 0` のケースでは概ね正しく機能する（経過が閾値を超えたら再認証）。
- **不足している可能性があること**
  - `max_age=0` かつ同一秒内認証で再認証が発火しない。ドキュメント記載（「0 は常に再認証を強制」）と実装が矛盾。
- **セキュリティ上の観点**
  - `max_age=0` はステップアップ／高保証を要求する RP が「今この瞬間の新鮮な認証」を求める用途で使う。
    ここが破れると、RP が要求したフレッシュネス保証を OP が満たさないまま既存セッションを流用しうる。
- **相互運用性**
  - `max_age=0` を `prompt=login` 同等に期待する RP との挙動差。conformance の `max_age` 系テストで顕在化しうる。

## 6. 改善・追加を検討する理由

- **Fidelity / セキュリティ**: `max_age=0` は「新鮮な認証」という明確な意味を持つ。境界で破れると
  仕様忠実性とセキュリティ（フレッシュネス保証）の双方を損なう。
- **導入しやすさ**: 判定ロジックは 1 関数に閉じており、`max_age=0` の特別扱い（または `>=` への変更）だけで済む。
  ただし `>=` に単純変更すると `max_age>0` 側で「ちょうど閾値秒」を再認証扱いにするため、
  `max_age=0` のみ特別扱いする実装が安全（後述）。
- **実装しない場合のリスク**: 高保証を要求する RP に対して黙ってフレッシュネス要求を無視する。
  ログイン直後ほど（authTime≈now）再現しやすく、テスト時に見逃しやすい。

## 7. 実装方針の候補

判断材料の整理（最終判断は人間）。

- 方針A（推奨）: `max_age === 0` を特別扱いして常に `true` を返す。
  ```ts
  export function requiresReauthentication(maxAge: number, authTime: number): boolean {
    if (maxAge <= 0) return true; // OIDC Core §3.1.2.1: max_age=0 は必ず再認証
    const now = Math.floor(Date.now() / 1000);
    return now - authTime > maxAge;
  }
  ```
  - `max_age>0` の既存挙動を変えず、`max_age=0` の MUST だけを正す。負値（不正入力）も安全側（再認証）へ倒す。
- 方針B: 全体を `>=` に変更（`now - authTime >= maxAge`）。
  - `max_age=0` は直る一方、`max_age=N`（>0）でも「経過ちょうど N 秒」を再認証扱いにするため
    厳密には仕様の "greater than" と食い違う。`max_age=0` 目的なら方針A の方が意図が明確。
- どちらでも、`max_age` の解釈（この判定は「再認証要否」であり、認可リクエストの検証段階での
  `max_age` パース／型検証は別レイヤ）を崩さないこと。

## 8. タスク案

- [ ] `auth-transaction.test.ts` に境界テストを先行追加（Red）:
  - [ ] `max_age=0`・`authTime===now` で `requiresReauthentication` が `true` を返す
  - [ ] `max_age=0`・`authTime<now` でも `true`
  - [ ] `max_age=10`・経過 10 秒ちょうどの挙動を固定（方針A なら現状維持で `false`、方針B なら `true`）
- [ ] 方針A で `requiresReauthentication` を修正（Green）
- [ ] ドキュメントコメントと実装の整合を取る（「0 は常に再認証」を実際に満たす）
- [ ] 可能なら `tests/e2e` に「`max_age=0` で必ず再認証画面へ遷移する」E2E を追加（CLI 生成 OP を対象）
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test` がパス
