# [P2] ID Token の予約クレームをユーザークレームで上書きできないよう denylist で塞ぐ

## ステータス

🟡 Medium / 未着手

## 背景

`buildIdTokenPayload` はユーザークレームを先に `Object.assign` してから protocol クレームを
代入するが、**代入の仕方が 2 種類ある**。

- **無条件代入**（`iss` / `sub` / `aud` / `exp` / `iat`）: 必ず上書きされる＝保護されている
- **条件付き代入**（`at_hash` / `nonce` / `auth_time` / `acr` / `amr`）:
  OP 側がその値を持たないとき（`undefined`）に**上書きが起きない**

今日はユーザークレームが `SCOPE_CLAIMS_MAP` の allowlist を通るため、
条件付きの 5 クレームには到達できない（実害は無い）。
しかし保護されているのは「たまたま経路が無いから」であり、**設計として保護されていない**。

具体的なリスク: 非標準クレームの写像を注入可能にする拡張
（`study-material/userinfo-custom-claims-and-scope-claim-mapping-extensibility.md`）を入れた瞬間、
これは実在の注入経路になる。`acr` を返すカスタム写像を利用者が定義し、かつ `acrResolver` を
設定していない構成では、resolver が返した任意の `acr` 値がそのまま ID Token の `acr` として
出力される。RP が `acr` を認可判断（例: 多要素認証済みかの判定）に使っていれば
**認証強度の詐称**が成立する。`amr` / `auth_time` も同様、`at_hash` はトークン束縛の詐称になる。

既存テストは `sub` の上書き防止しか固定していない
（`packages/core/src/token-response.test.ts:813-825`
`should not let user claims override required ID Token claims`）。

本タスクは、カスタムクレーム拡張の**前提条件**として、
protocol クレームの保護を「代入順序への暗黙の依存」から「明示的な denylist」へ格上げする。
拡張そのものの是非（方針 A〜D）とは独立に、単独で価値がある回帰防止・堅牢化。

## 対象ファイル

- `packages/core/src/token-response.ts`（`buildIdTokenPayload`）
- `packages/core/src/token-response.test.ts`（テスト追加）
- `packages/core/src/userinfo.ts`（`filterClaimsByScope` 側に置く場合）

## 仕様参照

- **OpenID Connect Core 1.0 §2 ID Token**
  `iss` / `sub` / `aud` / `exp` / `iat` は REQUIRED。`auth_time` / `nonce` / `acr` / `amr` / `azp` は
  条件付きまたは OPTIONAL だが、いずれも**OP が認証イベントについて主張するクレーム**であり、
  ユーザープロファイル由来の値で決まってよいものではない。
  - `acr`: Authentication Context Class Reference。OP の認証ポリシーが決める値
  - `amr`: Authentication Methods References。実際に使われた認証手段
  - `auth_time`: End-User が認証された時刻
- **OpenID Connect Core 1.0 §3.1.3.6 ID Token（`at_hash`）**
  `at_hash` は access_token の左半分ハッシュであり、ID Token とアクセストークンの束縛を示す。
  ユーザークレームで差し替えられると束縛検証が無意味になる。
- **OpenID Connect Core 1.0 §3.1.3.7 ID Token Validation (11)**
  `nonce` は Authentication Request と ID Token のワンタイム束縛。RP がリプレイ検知に使う。
- **OpenID Connect Core 1.0 §5.1 / §5.1.2**
  追加クレームは許容されるが、`sub` などの Standard Claims / protocol クレームの
  意味を上書きするものではない。

> 逐語確認は未実施（調査環境から openid.net へのフェッチが遮断されていたため）。
> 実装前に §2 のクレーム定義と §3.1.3.6 / §3.1.3.7 を一次資料で確認すること。

## 現状の実装

```ts
// packages/core/src/token-response.ts:423-462（buildIdTokenPayload）
const payload: Record<string, unknown> = {};

// OIDC Core 1.0 §5.4 / §12: scope に応じてユーザクレームを含める。
if (userClaims) {
  Object.assign(payload, filterClaimsByScope(userClaims, scope));
}

payload.iss = issuer;                                     // 無条件 → 保護される
payload.sub = subject;                                    // 無条件
const { aud, azp } = buildIdTokenAudience({ clientId, additional: idTokenAudiences });
payload.aud = aud;                                        // 無条件
if (azp !== undefined) payload.azp = azp;                 // ← 条件付き
payload.exp = issuedAt + expiresIn;                       // 無条件
payload.iat = issuedAt;                                   // 無条件
if (atHash !== undefined)   payload.at_hash = atHash;     // ← 条件付き
if (nonce !== undefined)    payload.nonce = nonce;        // ← 条件付き
if (authTime !== undefined) payload.auth_time = authTime; // ← 条件付き
if (acr !== undefined)      payload.acr = acr;            // ← 条件付き
if (amr !== undefined)      payload.amr = amr;            // ← 条件付き
```

コメントには「必須クレーム (iss/sub/aud/exp/iat/at_hash etc.) は後続の代入で上書きされるため
ここではユーザークレーム由来の sub などによる spoof を防げる」とあるが、
`at_hash` を含む条件付き代入の 5 クレームについては、
**OP 側が値を持つときにしか成立しない**主張になっている。

既存テスト（`packages/core/src/token-response.test.ts:813-825`）は
`sub: 'spoofed-sub'` のケースのみで、条件付き代入のクレームは対象外。

## 修正方針

- [ ] ID Token の予約クレーム名を定数として定義する
  ```ts
  /**
   * ユーザークレームで上書きしてはならない ID Token の protocol クレーム。
   * OIDC Core 1.0 §2 / §3.1.3.6 / §3.1.3.7: これらは OP が認証イベントについて
   * 主張する値であり、ユーザープロファイル由来の値で決まってよいものではない。
   * 特に acr / amr / auth_time は RP の認可判断に使われうるため、
   * 詐称されると認証強度の偽装が成立する。
   */
  export const RESERVED_ID_TOKEN_CLAIMS = [
    'iss', 'sub', 'aud', 'exp', 'iat', 'nbf', 'jti',
    'azp', 'at_hash', 'c_hash', 'nonce', 'auth_time', 'acr', 'amr',
  ] as const;
  ```
- [ ] `buildIdTokenPayload` で、ユーザークレームを `Object.assign` する前に
      予約クレーム名を除去する（代入順序への依存をやめる）
  ```ts
  if (userClaims) {
    const filtered = filterClaimsByScope(userClaims, scope);
    for (const reserved of RESERVED_ID_TOKEN_CLAIMS) {
      delete (filtered as Record<string, unknown>)[reserved];
    }
    Object.assign(payload, filtered);
  }
  ```
- [ ] `sub` は `filterClaimsByScope` が常に先頭に置く設計なので、除去したうえで
      直後の `payload.sub = subject` で確定させる（現行と同じ結果）
- [ ] 除去したことを利用者が気づけるようにするか（警告ログ / 黙って落とす）を決める
      — **黙って落とすことを推奨**。ID Token 発行時にログを出すと大量に出る可能性があり、
      かつ「予約名は使えない」は仕様として固定的なため
- [ ] `c_hash` は Hybrid Flow（未実装、`study-material/ext-multiple-response-types-hybrid-flow.md`）で
      使われるクレーム。現在は出力されないが、将来の追加時に穴にならないよう先に含めておく
- [ ] UserInfo 側（`filterClaimsByScope` の呼び出し元）に同じ保護が要るかを確認する
      — UserInfo レスポンスは JSON であり protocol クレームを持たない（`sub` のみ）ため、
      `sub` 保護は既存の `userinfo-sub-consistency-enforcement` で担保済み。
      本タスクの対象は ID Token に限定してよい

### 実装前に人間が確認すること

- [ ] `RESERVED_ID_TOKEN_CLAIMS` を公開 API として export するか（利用者が拡張時に参照できる）、
      内部定数に留めるかを決める

## テスト要件

TDD で先に Red を作る。テストケース名は「should + 動詞」形式。
アサーションは合格値を一意に固定する（`toBe` / `toEqual`。`expect.any` は使わない）。

`packages/core/src/token-response.test.ts`（`buildIdTokenPayload` / `generateTokenResponse`）:

- [ ] `should not let user claims set the acr claim when the OP resolved no acr`
      （最重要。`acrResolver` 未設定 + ユーザークレームに `acr` → payload に `acr` が無いこと）
- [ ] `should not let user claims set the amr claim when the OP resolved no amr`
- [ ] `should not let user claims set the auth_time claim when authTime is not provided`
- [ ] `should not let user claims set the at_hash claim when the ID Token is issued without one`
- [ ] `should not let user claims set the nonce claim when the request had no nonce`
- [ ] `should not let user claims set the azp claim when the audience is a single client`
- [ ] `should keep the OP-resolved acr when user claims also carry an acr`
      （OP が値を持つ場合も OP 側が勝つことを固定する）
- [ ] `should not let user claims override the iss claim`
- [ ] `should not let user claims override the exp claim`
- [ ] 既存の `should not let user claims override required ID Token claims`（`sub`）が
      無変更でパスすること
- [ ] `should still include non-reserved user claims filtered by scope`
      （予約名の除去が通常のクレームに影響しないこと。`name` / `email` を具体値で固定）

## 完了条件

- [ ] 上記テストがすべてパスする
- [ ] 予約クレームの保護が代入順序ではなく明示的な denylist で担保されている
- [ ] 既存の ID Token 発行挙動（予約名を含まないユーザークレーム）が一切変わっていない
- [ ] 実行コマンド:
  ```bash
  pnpm --filter @maronn-openid-connect/core test
  pnpm --filter @maronn-openid-connect/cli test
  ```
- [ ] `packages/core` の出荷物が変わるため changeset を追加する

## 関連

- `study-material/userinfo-custom-claims-and-scope-claim-mapping-extensibility.md`
  （本タスクを前提条件とする拡張。方針は未決）
- `study-material/done/userinfo-sub-consistency-enforcement.md`（UserInfo 側の `sub` 保護）
- `study-material/done/acr-values-request-propagation-to-id-token.md`（`acr` の解決経路）
