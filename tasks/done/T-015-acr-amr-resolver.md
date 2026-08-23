# T-015 [Major] acr/amr resolver 注入機構の追加

## ステータス

🟡 Major / 未着手

## 背景

T-009（Hold）では「acr の判定機構は未実装」としたが、Core が判定ロジックを持つのではなく、**呼び出し側から resolver として注入できるインタフェースを追加する**のが本タスクの目的。判定ロジック自体は各プロジェクトの要件によるため Core には書かない。

`packages/core/src/token-request.ts:179` のコメントにも「acr の判定機構は未実装 (T-009 Hold)」と明記されており、この Hold を注入機構という形で部分的に解除する。

## 対象ファイル

- `packages/core/src/authorization-request.ts`
- `packages/core/src/auth-transaction.ts`
- `packages/core/src/token-response.ts`
- `packages/cli/src/frameworks/hono/templates.ts`

## 仕様参照

- OIDC Core 1.0 §2: `acr` / `amr` クレームの定義
- OIDC Core 1.0 §12.1: refresh で発行する ID Token は初回認証時の `acr` / `amr` を保持する SHOULD

## 修正方針

- [ ] 適切なファイルに `AcrResolver` インタフェースを定義する

  ```typescript
  export type AcrResolver = (context: {
    userId: string;
    clientId: string;
    requestedAcrValues?: string;
  }) => Promise<{ acr: string; amr: string[] } | undefined>;
  ```

- [ ] `generateTokenResponse` の options に `acrResolver?: AcrResolver` を追加する
- [ ] `generateTokenResponse` 内で resolver を呼び出し、返された `acr` / `amr` を `IdTokenPayload` に渡す
- [ ] resolver が `undefined` の場合は従来どおり `acr` / `amr` も `undefined`（T-009 hold 相当の動作を維持）
- [ ] CLI テンプレートで `acrResolver` を外部注入できる型を生成コードに反映（stub として `undefined` を渡す形）

## テスト要件

- [ ] `acrResolver` が返す `acr` / `amr` が ID Token に反映されること
- [ ] `acrResolver` が `undefined` を返した場合、ID Token の `acr` / `amr` も `undefined` のままであること
- [ ] `acrResolver` を渡さなかった場合、従来動作と変わらないこと

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` および `pnpm --filter @maronn-openid-connect/cli test` がパスすること
