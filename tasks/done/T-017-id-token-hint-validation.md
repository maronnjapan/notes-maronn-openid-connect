# T-017 [Major] `id_token_hint` 検証ヘルパーの追加

## ステータス

🟡 Major / 未着手

## 背景

`authorization-request.ts` は `id_token_hint` パラメータを受け取るが、Core が検証ヘルパーを提供していないため、呼び出し側（CLI 生成コード）が `prompt=none` や re-authentication フローで hint の有効性を判定できない。

現状では `id_token_hint` の値は AuthorizationRequest オブジェクトに格納されるだけで、署名検証・iss/aud/exp チェックが実施されない。

## 対象ファイル

- `packages/core/src/id-token.ts`（新規関数）
- `packages/cli/src/frameworks/hono/templates.ts`（authorize ハンドラへの組み込み）

## 仕様参照

- OIDC Core 1.0 §3.1.2.1: `id_token_hint` が提供された場合、OP は hint の署名・iss・aud・exp を検証し、sub を信頼すること
- OIDC Core 1.0 §3.1.2.6: `prompt=none` と `id_token_hint` の組み合わせ動作

## 修正方針

- [ ] `packages/core/src/id-token.ts` に以下のシグネチャでヘルパーを追加する

  ```typescript
  export async function validateIdTokenHint(
    hint: string,
    options: {
      expectedIss: string;
      expectedAud: string;
      jwks: JsonWebKeySet;
    }
  ): Promise<{ sub: string; [key: string]: unknown }>;
  ```

- [ ] 検証内容
  1. JWT をデコードして alg を取得
  2. JWKS から `kid` 一致（または alg 一致）の鍵を選択
  3. 署名を検証
  4. `iss`・`aud`・`exp` を検証
  5. 検証成功時は payload を返す

- [ ] 検証失敗時は `login_required` に相当する型付き Error を投げる（`prompt=none` フローで使いやすくする）

- [ ] CLI テンプレートの authorize ハンドラで `id_token_hint` が存在するとき `validateIdTokenHint` を呼び出すコードを生成する

## テスト要件

- [ ] 有効な `id_token_hint` → `sub` を含む payload を返すこと
- [ ] 有効期限切れの hint → エラーを投げること
- [ ] `iss` 不一致 → エラーを投げること
- [ ] `aud` 不一致 → エラーを投げること
- [ ] 署名不正 → エラーを投げること

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` および `pnpm --filter @maronn-openid-connect/cli test` がパスすること
