# [P3] `supportedGrantTypes` の契約明記と `grant_types` 既定値の二重定義解消

## ステータス

🟢 Low / 未着手

## 背景

`TokenRequestContext.supportedGrantTypes` は名前からは「OP がサポートする grant_type の一覧」に読めるが、実際には
`validateGrantTypeSupported` の中で `authorization_code` / `refresh_token` の型比較と AND を取るため、
**既知の 2 値を絞り込むことしかできない**。この配列に `urn:ietf:params:oauth:grant-type:device_code` を足しても
その grant_type が有効になることはなく、`unsupported_grant_type` で拒否される。

現在の JSDoc は「この一覧に無い grant_type は `unsupported_grant_type` で拒否する」と拒否側だけを書いており、
「一覧に足しても有効化されない」ことは書かれていない。core を直接ライブラリとして使う利用者
（CLAUDE.md が core の役割として挙げる高度な組み込みユースケース）は、この配列に値を足せば拡張グラントを
載せられると読み違える余地がある。

併せて、クライアント別の grant 認可における `grantTypes` の既定値が 2 箇所で食い違っている。

| 実装 | 既定値 |
|---|---|
| `packages/core/src/token-request.ts` `validateClientGrantType` | `client.grantTypes ?? ['authorization_code']` |
| `packages/experimental/src/device-authorization-grant/device-code-grant.ts` `validateDeviceCodeGrantAllowed` | `(client.grantTypes ?? []).includes(...)` |

`device_code` の URN は前者の既定値にも含まれないため、現時点で判定結果は一致する。
とはいえ同じ規則（RFC 7591 §2 の `grant_types` 既定は `["authorization_code"]`）が別々の形で 2 度書かれており、
将来 core 側の既定値を変えたときに experimental 側だけ取り残される。

本タスクは**挙動を変えない**。契約の明記と、既定値が食い違っている理由の明示、その契約を固定する
テストの追加に限定する。grant_type の拡張点を core に設けるかどうかは
`study-material/token-endpoint-grant-type-extension-point.md` で検討中であり、本タスクの範囲外である。

## 対象ファイル

- `packages/core/src/token-request.ts`（`supportedGrantTypes` の JSDoc、`validateGrantTypeSupported` の JSDoc）
- `packages/core/src/token-request.test.ts` または `packages/core/src/token-request-steps.test.ts`（契約テストの追加先）
- `packages/experimental/src/device-authorization-grant/device-code-grant.ts`（`validateDeviceCodeGrantAllowed` のコメント）

## 仕様参照

- **RFC 6749 §5.2**: `unsupported_grant_type` は「認可サーバがそのグラントタイプに対応していない」、
  `unauthorized_client` は「認証済みクライアントがそのグラントタイプの使用を認可されていない」。
  本タスクはこの切り分けを変えない。
- **RFC 6749 §4.5 / §8.3**: 拡張グラントは絶対 URI 形式の `grant_type` 値で定義され、IANA レジストリへ登録される。
  core が 2 値に閉じているのは仕様の要求ではなく実装の選択である旨を JSDoc に残す。
- **RFC 7591 §2 / OpenID Connect Dynamic Client Registration 1.0 §2**: クライアントメタデータ `grant_types` の既定値は
  `["authorization_code"]`。既定値の根拠はこの条文である。
- 検討の詳細は `study-material/token-endpoint-grant-type-extension-point.md` を参照。

## 現状の実装

`packages/core/src/token-request.ts`:

```ts
  /**
   * OP として提供する grant_type の一覧（機能トグル）。
   * 未指定時は `['authorization_code', 'refresh_token']`（従来挙動）。
   * この一覧に無い grant_type は RFC 6749 §5.2 の `unsupported_grant_type` で拒否する。
   * クライアント別の許可（`TokenClientInfo.grantTypes` → `unauthorized_client`）とは
   * 別軸の「OP 全体でのサポート有無」を表す。
   */
  supportedGrantTypes?: string[];
```

```ts
export function validateGrantTypeSupported(
  grantType: string | undefined,
  supportedGrantTypes: string[] = [...DEFAULT_SUPPORTED_GRANT_TYPES],
): 'authorization_code' | 'refresh_token' {
  ...
  if (
    (grantType !== 'authorization_code' && grantType !== 'refresh_token') ||
    !supportedGrantTypes.includes(grantType)
  ) {
    throw new TokenError(
      TokenErrorCode.UnsupportedGrantType,
      `Unsupported grant_type: ${grantType}`
    );
  }
  return grantType;
}
```

型比較と `supportedGrantTypes.includes` が OR で結ばれているため、配列への追加は無効である。
JSDoc はこの片方向性を述べていない。

`packages/experimental/src/device-authorization-grant/device-code-grant.ts`:

```ts
export function validateDeviceCodeGrantAllowed(client: DeviceCodeGrantClient): void {
  if (!(client.grantTypes ?? []).includes(DEVICE_CODE_GRANT_TYPE)) {
    throw new DeviceAuthorizationError(
      'unauthorized_client',
      'The client is not authorized to use the device_code grant',
    );
  }
}
```

既定値が `[]` であり、core の `['authorization_code']` と異なる。

## 修正方針

- [ ] `TokenRequestContext.supportedGrantTypes` の JSDoc に、この配列が**絞り込み専用**であることを明記する。
      「既知の 2 値（`authorization_code` / `refresh_token`）のうちどれを有効にするかを選ぶための配列であり、
      未知の grant_type を足しても有効化されない」ことを書く。
- [ ] `validateGrantTypeSupported` の JSDoc に、拡張グラント（RFC 6749 §4.5 の URN 形式）を扱うには
      この関数を呼ぶ前に分岐する必要がある旨と、その実例が CLI 生成コードの device_code / token-exchange 分岐である旨を書く。
- [ ] `validateDeviceCodeGrantAllowed` に、既定値を `[]` にしている理由をコメントで残す。
      RFC 7591 §2 の既定 `["authorization_code"]` に `device_code` の URN は含まれないため、
      既定を補っても補わなくても結論が変わらないことを書く。core の `validateClientGrantType` を参照する。
- [ ] 実装コードそのものは変更しない（挙動を変えないタスクである）。

## テスト要件

- [ ] `should reject an unknown grant_type even when it is listed in supportedGrantTypes`
      （`supportedGrantTypes: ['authorization_code', 'urn:ietf:params:oauth:grant-type:device_code']` を渡し、
      `grant_type` に当該 URN を指定したとき `unsupported_grant_type` になることを固定する）
- [ ] `should reject refresh_token when supportedGrantTypes contains only authorization_code`
      （絞り込みが機能することの確認。既存テストにあれば追加しない）
- [ ] `should accept authorization_code when supportedGrantTypes is omitted`
      （既定値の確認。既存テストにあれば追加しない）
- [ ] `validateDeviceCodeGrantAllowed` について、`grantTypes` 未指定のクライアントが `unauthorized_client` になることを固定する
      （`device-code-grant.test.ts` に既存でなければ追加する）

## 完了条件

- [ ] `supportedGrantTypes` の JSDoc を読んだ利用者が、未知の grant_type を足しても有効化されないと分かる
- [ ] `validateDeviceCodeGrantAllowed` の既定値が core と異なる理由がコメントから読み取れる
- [ ] 上記テストが追加され、既存テストが壊れていない

```bash
pnpm --filter @maronn-openid-connect/core test
pnpm --filter @maronn-openid-connect/experimental test
pnpm test
```

- [ ] `packages/experimental/src`（`device-code-grant.ts` のコメント）に触れるため、CLAUDE.md の規約どおり
      changeset を手で書かない。main への push で CI が patch の changeset を自動生成する
      （`.github/scripts/ensure-experimental-changeset.mjs`）。minor / major を指定すると
      `pnpm run test:release-contract` が落ちる
