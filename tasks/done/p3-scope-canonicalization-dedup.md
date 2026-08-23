# [P3] Authorization Endpoint の `scope` を重複除去し Token Endpoint と正規化を揃える

## ステータス

🟢 Low / 未着手

## 背景

`scope` は OAuth 2.0 / OIDC で **空白区切りの集合（set）** として扱う値である。
本リポジトリでは **Token Endpoint（refresh_token grant）は `[...new Set(...)]` で重複除去しているのに、Authorization Endpoint は重複除去していない**という非対称がある。

その結果、`scope=openid openid profile` のような重複を含む認可リクエストは、`["openid","openid","profile"]` のまま
認可コード → アクセストークンの `scope` クレーム → token response の `scope` 値へ重複を保ったまま伝播する。
さらに、同一 grant でも初回発行（authz 経路）とリフレッシュ後（dedup 経路）で `scope` 表現が変わりうる。

これは MUST 違反ではないが、(1) 発行物の `scope` 表現が入力の冗長性に依存して非決定的になる、
(2) `scope` を文字列一致で比較するリソースサーバ／クライアントとの相互運用で稀な誤判定を生む、
(3) CLAUDE.md の「アサーションは合格値を一意に固定する」方針に反してテストの固定値化を阻害する、という問題がある。

検討の詳細は `study-material/done/scope-canonicalization-consistency.md` を参照。

## 対象ファイル

- `packages/core/src/authorization-request.ts`（`scope` 構築箇所 L835 付近）
- `packages/core/src/authorization-request.test.ts`
- （方針 B を採る場合）`packages/core/src` に `parseScope` ヘルパを新設

## 仕様参照

- RFC 6749 §3.3（Access Token Scope）— scope は「space-delimited, case-sensitive strings」の**集合**。順序に意味はなく、重複した値は同一権限を二重表現するだけ。
  https://www.rfc-editor.org/rfc/rfc6749#section-3.3
- RFC 6749 §5.1 / OIDC Core 1.0 §3.1.3.3 — Token Response は付与 scope が要求と異なるとき `scope` を返す。正規化済み集合を返す方がクライアント比較が素直。
  https://openid.net/specs/openid-connect-core-1_0.html#TokenResponse
- OAuth 2.1 draft §3.2.2.1 — scope 意味論は RFC 6749 を踏襲。

## 現状の実装

- `authorization-request.ts:835` 付近: `const scope = scopeValue.split(' ').filter((s) => s.length > 0);` — **dedup していない**。
- ここで作られた配列は `offline_access` フィルタ・`openid` チェックを経て認可コードに保存され（同 L923 `scope,`）、Token Endpoint で `authCode.scope` としてそのまま透過。
- `token-request.ts:516` 付近: refresh_token grant の縮小要求では `const uniqueRequestedScopes = [...new Set(requestedScopes)];` で**重複除去している**（非対称の出どころ）。
- `token-response.ts:293 / 373` 付近: access token クレーム・token response とも `scope: scope.join(' ')` で配列をそのまま出力 → 重複が発行物まで伝播。

## 修正方針

- [ ] 正規化方針を決める（**方針 A: authz 側にインライン `[...new Set(...)]`** / **方針 B: 共通 `parseScope` ヘルパに集約**）。挿入順は保持する（`Set` は挿入順保持）。
- [ ] `authorization-request.ts:835` 付近で `scope` を重複除去する。`openid` チェック・`offline_access` フィルタの前段に差し込む。
  ```ts
  // RFC 6749 §3.3: scope は集合。重複除去して Token Endpoint と正規化を揃える。
  const scope = [...new Set(scopeValue.split(' ').filter((s) => s.length > 0))];
  ```
- [ ] 方針 B を採る場合、`parseScope(value: string): string[]`（split → filter(空) → dedup, 挿入順保持）を新設し、authz / token / refresh の全経路で共有する。
- [ ] Breaking change が無いこと（重複除去は権限を変えない）をコメントで明示。

## テスト要件

- [ ] `scope=openid openid profile` の認可リクエストで、認可コードに保存される granted scope が `['openid','profile']`（重複なし・順序固定）であること。
- [ ] 上記コードを交換して得た access token の `scope` クレームが `'openid profile'`（一意値で固定）であること。
- [ ] 同じく token response の `scope` 値が `'openid profile'` であること。
- [ ] 初回発行 scope とリフレッシュ後 scope の表現が一致すること（どちらも `'openid profile'`）。
- [ ] 既存の正常系 scope テスト（`openid profile email` 等）が回帰しないこと。

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- Authorization Endpoint と Token Endpoint の scope 正規化（重複除去）が一致し、発行物の `scope` が入力の重複に依存しない決定的な値で固定されること
- 生成 OP の `conformance.test.ts` で発行物 scope を固定しているテストがあれば、`packages/cli` テンプレート経由で整合するよう更新されていること
