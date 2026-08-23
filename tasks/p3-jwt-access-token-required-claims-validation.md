# [P3] JWT アクセストークンの必須クレーム（`client_id` / `jti`）を型と発行時検証で強制する

## ステータス

🟢 Low / 未着手

## 背景

RFC 9068 §2.2 は JWT アクセストークンの必須クレームとして
`iss` / `exp` / `aud` / `sub` / `client_id` / `iat` / `jti` の **7 つすべてを REQUIRED** と定めている。

現状の `packages/core/src/access-token.ts` は:

- 型 `AccessTokenPayload` で `client_id?: string` / `jti?: string` を **optional** として宣言している
- 発行前検証 `validatePayload()` が `iss` / `sub` / `aud` / `exp` / `iat` の 5 つしか検査していない

同梱の `buildAccessTokenPayload()` は `client_id` も `jti` も必ず設定するため、
**生成 OP の既定経路では RFC 9068 違反は起きない**。しかし core は
「ステップ関数を個別に呼び出して差し替えられる」ことを設計方針にしており
（`packages/core/src/index.ts` のステップ関数 export、CLI 生成コードもその形）、
利用者が payload を自前で組み立てて `generateAccessToken()` / `AccessTokenIssuer.issue()` を
呼ぶ経路が正規のユースケースとして存在する。その経路では
`client_id` / `jti` を落としても検出されず、**RFC 9068 非準拠のアクセストークンが署名・発行される**。

`jti` の欠落はさらに実害が大きい。`AccessTokenIssuer` の契約
（`packages/core/src/access-token-issuer.ts` の JSDoc）は「戻り値は発行ごとに一意でなければならない」と
明記しており、JWT issuer はその一意性を `payload.jti` に依存している。RS256（RFC 8017 §8.2 の
RSASSA-PKCS1-v1_5）は決定的な署名方式なので、`jti` が無いと同一秒・同一入力の 2 回の発行が
**バイト単位で同一のトークン文字列**になり、トークン文字列をキーにするストアで後勝ちの上書きが起きる。
その結果、先の grant に対する `grantId` 単位の失効（認可コード再利用検知・同意撤回・
リフレッシュトークンファミリー失効）が黙って効かなくなる。
この事象自体は `study-material/done/token-value-uniqueness-same-second-jwt-reissuance-collision.md` /
`tasks/done/p1-token-value-uniqueness-and-refresh-idtoken-iat.md` で扱い済みだが、
**契約が型と実行時検証で強制されていない**点が本タスクの差分である。

Basic OP certification のブロッカーではない（JWT アクセストークンは Basic OP の必須要件ではない）。
本タスクは型と実装の不整合の解消であり、破壊的変更ではなく厳格化のみである。

検討詳細は `study-material/jwt-access-token-rfc9068.md`（RFC 9068 準拠マップ）を参照。

> 関連（重複回避）:
> - `jti` を発行すること自体は `tasks/done/p2-jwt-access-token-jti.md` で実装済み。本タスクは
>   「欠落を検出する」側の差分。
> - `aud` の非空要件は `validatePayload` に実装済み（`tasks/done/p1-jwt-access-token-aud-default.md`）。
> - Opaque アクセストークンはトークン文字列にクレームを含まないため本タスクの対象外
>   （`createOpaqueAccessTokenIssuer` は `generateAccessToken` を呼ばない）。

## 対象ファイル

- `packages/core/src/access-token.ts`（`AccessTokenPayload` 型 / `validatePayload`）
- `packages/core/src/access-token.test.ts`
- `packages/core/src/token-response.ts`（`buildAccessTokenPayload` の戻り値型が変わる場合）
- `packages/core/src/access-token-issuer.ts`（Opaque 経路が影響を受けないことの確認）

## 仕様参照

- **RFC 9068 §2.2 Data Structure**:
  > The following claims are used in the JWT access token data structure.
  > **iss** REQUIRED / **exp** REQUIRED / **aud** REQUIRED / **sub** REQUIRED /
  > **client_id** REQUIRED / **iat** REQUIRED / **jti** REQUIRED
  — https://www.rfc-editor.org/rfc/rfc9068#section-2.2
- **RFC 7519 §4.1.7 "jti" (JWT ID) Claim**:
  > The identifier value MUST be assigned in a manner that ensures that there is a negligible
  > probability that the same value will be accidentally assigned to a different data object
  — https://www.rfc-editor.org/rfc/rfc7519#section-4.1.7
- **RFC 9068 §2.1**: `typ` は `at+jwt`（実装済み）。
- **RFC 8017 §8.2 RSASSA-PKCS1-v1_5**: 決定的署名方式であることの根拠（同一 payload → 同一署名）。

## 現状の実装

```ts
// packages/core/src/access-token.ts
export interface AccessTokenPayload {
  iss: string;
  sub: string;
  aud: string[];
  exp: number;
  iat: number;
  nbf?: number;
  jti?: string;        // ← RFC 9068 §2.2 では REQUIRED
  scope?: string;
  client_id?: string;  // ← RFC 9068 §2.2 では REQUIRED
  [key: string]: unknown;
}

function validatePayload(payload: AccessTokenPayload): void {
  if (!payload.iss) throw new Error('Missing required claim: iss');
  if (!payload.sub) throw new Error('Missing required claim: sub');
  if (payload.aud === undefined || payload.aud === null) throw new Error('Missing required claim: aud');
  if (!Array.isArray(payload.aud) || payload.aud.length === 0) throw new Error('Invalid aud claim: must be a non-empty array');
  if (payload.exp === undefined || payload.exp === null) throw new Error('Missing required claim: exp');
  // ... exp の過去チェック ...
  if (payload.iat === undefined || payload.iat === null) throw new Error('Missing required claim: iat');
  // client_id / jti は一切検査されない
}
```

`jti` が optional である理由は JSDoc に「Opaque issuer 向けに payload を組み立てられるようにするため」と
記されているが、`createOpaqueAccessTokenIssuer` は payload を使わずランダム文字列を返すだけなので、
**Opaque 経路のために `jti` を optional に保つ必要は実際には無い**（要確認事項として下記に含める）。

## 修正方針

- [ ] `createOpaqueAccessTokenIssuer` が `payload` を参照していないこと、および
      `generateAccessToken` を呼ばないことを確認する（`jti` を必須化しても Opaque 経路が壊れないことの前提）
- [ ] `validatePayload` に RFC 9068 §2.2 の残り 2 クレームの検査を追加する
  - `client_id` が非空文字列であること
  - `jti` が非空文字列であること
  - エラーメッセージは既存の `Missing required claim: <name>` 形式に揃える
- [ ] `AccessTokenPayload` の `client_id` / `jti` を必須フィールドへ昇格させるか判断する
  - 昇格する場合、`buildAccessTokenPayload` は既に両方を必ず設定しているため戻り値型は自然に満たされる
  - 昇格しない場合は、JSDoc に「`generateAccessToken` に渡す時点では両方 REQUIRED」と明記する
  - 判断材料: 型を必須にすると、payload を自前で組む利用者にコンパイル時エラーが出る（早期発見）。
    一方で `AccessTokenPayload` は Opaque 経路でも型として使われるため、
    昇格の影響範囲を grep で棚卸ししてから決める
- [ ] `validatePayload` に RFC 9068 §2.2 の条文参照コメントを添える（既存の `aud` 検証と同じ書式）

実装イメージ:

```ts
  // RFC 9068 §2.2: client_id は JWT アクセストークンの REQUIRED クレーム。
  // リソースサーバがトークンの提示元クライアントを識別するために必要。
  if (!payload.client_id) {
    throw new Error('Missing required claim: client_id');
  }

  // RFC 9068 §2.2: jti は REQUIRED。RFC 7519 §4.1.7 の一意性要件を満たす値であること。
  // RS256 は決定的署名（RFC 8017 §8.2）なので、jti が無いと同一秒の再発行が
  // バイト同一のトークンになり、トークン文字列をキーにするストアで上書きが起きる。
  if (!payload.jti) {
    throw new Error('Missing required claim: jti');
  }
```

## テスト要件

- [ ] `client_id` を欠いた payload で `generateAccessToken` が `Missing required claim: client_id` で throw する
- [ ] `client_id` が空文字列の payload で throw する
- [ ] `jti` を欠いた payload で `generateAccessToken` が `Missing required claim: jti` で throw する
- [ ] `jti` が空文字列の payload で throw する
- [ ] `buildAccessTokenPayload()` の戻り値をそのまま渡した場合は従来どおり成功する（回帰固定）
- [ ] `createOpaqueAccessTokenIssuer().issue()` は `client_id` / `jti` を欠く payload でも成功する
      （Opaque はクレームを含まないため検証対象外であることの固定）
- [ ] 既存の `iss` / `sub` / `aud` / `exp` / `iat` の負テストが回帰しない
- [ ] （型を必須化する場合）`AccessTokenPayload` を自前で構築するテストが型エラーにならないよう更新済みであること

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- `pnpm --filter @maronn-openid-connect/cli test` がパスすること（生成テンプレートが影響を受けないことの確認）
- `study-material/jwt-access-token-rfc9068.md` の準拠マップから、本タスクに対応する行の状態を更新すること
