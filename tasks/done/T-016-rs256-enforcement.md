# T-016 [Critical] RS256 キー存在チェック（Discovery との整合性保証）

## ステータス

🔴 Critical / 未着手

## 背景

`id-token.ts` は `getJwaAlgorithm(privateKey)` で鍵から alg を自動判定（RS256/ES256 等）する。`discovery.ts` は `idTokenSigningAlgValuesSupported` に RS256 が含まれることを必須チェックするが、**実際に渡される鍵セットに RS256 対応鍵が含まれない場合でも通過する**。

EC 鍵のみが渡されると Discovery では RS256 を advertise しながら ES256 で署名するという矛盾が生じ、クライアントの ID Token 検証が失敗する。

### 仕様上の要件

OIDC Core 1.0 §15.1 は「RS256 を**サポートしなければならない（MUST be supported）**」と定めている。これは「RS256 のみ使用しなければならない」ではなく、「鍵セットの中に RS256 対応鍵が少なくとも 1 つ存在すること」を意味する。

したがって ES256 鍵を追加で登録することは許可される。Discovery の `id_token_signing_alg_values_supported` は、登録された鍵セットに対応するアルゴリズムを全て列挙すべきである。

## 対象ファイル

- `packages/core/src/signing-key.ts`
- `packages/core/src/discovery.ts`

## 仕様参照

- OIDC Core 1.0 §15.1: RS256 はデフォルトアルゴリズム（MUST be supported）
- OIDC Conformance Profiles v3.0 Basic OP: RS256 必須

## 修正方針

### signing-key.ts

- [ ] 鍵セット全体を受け取り、RS256 対応鍵（RSASSA-PKCS1-v1_5 / SHA-256）が少なくとも 1 つ含まれることを検証するヘルパーを追加する

  ```typescript
  export function assertHasRs256Key(keys: CryptoKey[]): void;
  ```

  - RS256 鍵が 1 つも含まれない場合はエラーを投げる
  - ES256 等の他アルゴリズムの鍵が混在していてもエラーにしない

### discovery.ts

- [ ] `buildProviderMetadata` で `idTokenSigningAlgValuesSupported` を利用者が手動指定する現行の方式を廃止し、渡された鍵セットから自動導出する方式に変更する
  - 鍵セット内の各鍵のアルゴリズムを `getJwaAlgorithm` で取得し、重複を除いて列挙する
  - RS256 鍵が含まれない場合は `assertHasRs256Key` によりエラーを投げる

## テスト要件

- [ ] RS256 鍵のみを渡した場合、`id_token_signing_alg_values_supported` が `['RS256']` になること
- [ ] RS256 鍵と ES256 鍵を両方渡した場合、両アルゴリズムが `id_token_signing_alg_values_supported` に含まれること
- [ ] RS256 鍵を含まない鍵セットを渡した場合にエラーが投げられること

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` がパスすること
