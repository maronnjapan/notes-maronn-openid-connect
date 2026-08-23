# Discovery (`/.well-known/openid-configuration`) Cache-Control / ETag ヘッダ整備

## ステータス

🟡 Minor（相互運用性 / 運用品質）/ 未着手

## 1. このトピックで確認したいこと

- 本リポジトリの Discovery エンドポイント（`/.well-known/openid-configuration`）が **HTTP キャッシュヘッダを返していない** 現状を確認する。
- JWKS（`/.well-known/jwks.json`）は既に `Cache-Control: public, max-age=3600` を設定済みであり（`packages/sample/src/oidc-provider/routes/jwks.ts:90`）、Discovery 側との整合が取れていない。
- クライアントライブラリ（`openid-client`、`oidc-client-ts`、`appauth-android` 等）は Discovery メタデータをキャッシュして使い回す。サーバ側がキャッシュヘッダを出さないと、ライブラリは自前のキャッシュポリシー（多くは「無期限」または「短い既定値」）に頼ることになり、メタデータ更新時の伝播が予測不能になる。
- 本ファイルは Discovery のキャッシュ可能性に絞った差分タスク。JWKS の `Cache-Control` 値設計は既存の `jwks-endpoint-comprehensive.md` で扱われており、Discovery 固有の論点だけを記載する。

## 2. 関連する仕様・基準

共通の Discovery 仕様説明は `study-material/basic-op-requirement-traceability.md` §3.3 を参照。本トピック固有の差分のみ:

### 2.1 OpenID Connect Discovery 1.0 §4 — エンドポイントのキャッシュ可能性

OIDC Discovery 1.0 §4 は Discovery レスポンスについて `Content-Type: application/json` を MUST と規定しているが、`Cache-Control` の具体値は規定しない。代わりに、メタデータが **時間とともに変わる可能性がある**（鍵ローテーション、エンドポイント変更、新規 scope サポート等）ことを暗黙の前提としている。

### 2.2 RFC 8414 §3.2 — AS メタデータの取得

RFC 8414 §3.2 は AS メタデータの取得について「クライアントは取得結果をキャッシュしてよい」と明示している。サーバ側のキャッシュ制御ヘッダ運用は MUST/SHOULD ではないが、`Cache-Control` を返すことで「キャッシュ可能期間」をクライアントに伝達するのが標準的な HTTP セマンティクス（RFC 9111）。

### 2.3 RFC 9111 (HTTP Caching) — キャッシュ指示の基本

- `Cache-Control: public, max-age=<seconds>` で **CDN・ブラウザ・中継プロキシ**を含む共有キャッシュに対する最大有効期間を指示。
- `ETag: "<opaque>"` でリソースのバージョン指紋を返し、クライアントは `If-None-Match` で再検証できる（`304 Not Modified` をサポートできる）。
- 公開メタデータには PII が含まれないため `public` が適切。`private` を使う必要はない。
- Discovery / JWKS は鍵ローテーションの安全性に直結するため、`max-age` を長くしすぎるとローテーション伝播が遅れる。短くしすぎると無駄なリクエストが増える。**1〜24 時間（3600〜86400）** が業界慣行。

### 2.4 鍵ローテーションとの連動（既存 `signing-key-rotation-operations.md` との接続）

- Discovery の `jwks_uri` は通常固定だが、`id_token_signing_alg_values_supported` などは鍵セット変更で値が変わりうる。
- 鍵ローテーション直前後は Discovery と JWKS の **両方の `max-age` を短縮**する運用が推奨される。これは本ファイルではなく `signing-key-rotation-operations.md` のローテーション運用の中で扱う。
- 本ファイルではあくまで「定常状態の `Cache-Control` 値を返す責務がサーバ側にある」という骨格を確定する。

## 3. 参照資料

- OpenID Connect Discovery 1.0 §4 — https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderConfig
- RFC 8414 §3.2 — https://www.rfc-editor.org/rfc/rfc8414#section-3.2 （メタデータ取得とキャッシュ可能性）
- RFC 9111 (HTTP Caching) — https://www.rfc-editor.org/rfc/rfc9111
  - §5.2 `Cache-Control` フィールド
  - §8.8 `ETag` と再検証
- 本リポジトリ内: `study-material/jwks-endpoint-comprehensive.md` §3.4（JWKS のキャッシュ運用、既存）
- 本リポジトリ内: `study-material/signing-key-rotation-operations.md`（鍵ローテーションとキャッシュ短縮、既存）

## 4. 現在の実装確認

- `packages/sample/src/oidc-provider/routes/discovery.ts`: `c.json(metadata)` のみで、`Cache-Control` / `ETag` / `Last-Modified` のいずれも返していない。
- `packages/sample/src/oidc-provider/routes/jwks.ts:90`: `c.header('Cache-Control', 'public, max-age=3600')` を設定済み（既存）。
- `packages/cli/src/frameworks/hono/templates.ts`: CLI が生成する Discovery テンプレートも `Cache-Control` を出していない（要確認）。
- `packages/core/src/discovery.ts` `buildProviderMetadata`: メタデータ本体の生成のみで、HTTP ヘッダは責務外（コア層は HTTP に依存しない設計）。

## 5. 現在の実装との差分

満たしていること:

- ✅ メタデータ本体は OIDC Discovery 1.0 / RFC 8414 に準拠（必須フィールド出力）。

不足／要確認:

- 🟡 **Discovery レスポンスに `Cache-Control` が無い**: クライアントライブラリのキャッシュ戦略がライブラリ依存になる。例えば `node-openid-client` は `cache-control` ヘッダを尊重するが、ヘッダが無い場合は自前のフォールバック（典型的には「キャッシュしない」または「呼び出しごとに取得」）になり、リクエスト数が増える。
- 🟡 **JWKS とのヘッダ整合が無い**: JWKS が `max-age=3600` を返すのに Discovery が無キャッシュだと、Discovery 経由で得た `jwks_uri` を取得しに行く流れが**非対称**になる。
- 🟢 **`ETag` 不在**: 必須ではないが、`304 Not Modified` をサポートできない。Discovery は数百バイト〜数 KB なので `ETag` 効果は小さいが、PoC 利用者にメタデータの変更検知（`If-None-Match`）を提供できる。
- 🟢 **`Last-Modified` 不在**: `ETag` と同程度の効果。`buildProviderMetadata` がメタデータの「実体生成タイムスタンプ」を返さないため、設定変更時に `Last-Modified` を更新する仕組みが必要になる。

セキュリティ観点:

- メタデータは公開情報であり PII を含まないため `public` キャッシュで問題なし。
- **過度に長い `max-age` は鍵ローテーション時に旧鍵情報を引きずる**（実害は JWKS 側のキャッシュだが、`id_token_signing_alg_values_supported` などのメタデータが変わるケースもある）。
- `Cache-Control: no-store` は不要（PII 無し）。Token / UserInfo エンドポイントが `no-store` なのと混同しないこと。

## 6. 改善・追加を検討する理由

価値:

- **相互運用性向上**: クライアントライブラリのキャッシュ動作が予測可能になる。Discovery を毎回フェッチするライブラリでも、サーバが `max-age=3600` を返せば 1 時間に 1 回に減る。
- **JWKS との対称性**: JWKS / Discovery を同じ `max-age=3600` で揃えることで、運用の認知負荷が下がる。
- **ローテーション運用の基礎**: 鍵ローテーション時に `Cache-Control: max-age=<短い値>` を一時的に出す運用（`signing-key-rotation-operations.md` 参照）の前提として、定常時の値が確定している必要がある。
- **`ETag` は任意**: 実装コストが小さいわけではない（メタデータ本体の hash 計算と保存が要る）。優先度は低い。

導入難易度:

- 🟢 **Cache-Control 追加**: 極小。`routes/discovery.ts` で 1 行追加するだけ。CLI テンプレートも同じく 1 行。
- 🟡 **ETag 追加**: 中。メタデータ JSON の SHA-256 を計算して `ETag` に詰めるロジックが要る。`If-None-Match` の検証も加える必要がある。
- 🟢 **`max-age` 値の選定**: 定常時 3600 秒（JWKS と揃える）が妥当。利用者が `ProviderConfig` で上書きできるとさらに良い。

実装しない場合のリスク:

- クライアント側のキャッシュ戦略がバラつき、Discovery を毎リクエスト取得するライブラリでサーバ負荷が増える。
- 鍵ローテーション時にメタデータ伝播のコントロールができない。
- 「OIDC Discovery 完全対応」の運用面での弱点が残る。

## 7. 実装方針の候補

### 方針A（最小・固定値）

- `routes/discovery.ts` に `c.header('Cache-Control', 'public, max-age=3600')` を追加。
- CLI テンプレートにも同じ行を追加。
- JWKS との対称性を確保。
- `ETag` は導入しない。

### 方針B（設定可能化）

- `ProviderConfig` に `discoveryCacheMaxAgeSeconds?: number` を追加（デフォルト 3600）。
- `routes/discovery.ts` で context から取得し `Cache-Control: public, max-age=<value>` を返す。
- 鍵ローテーション時に runtime で短縮できる（環境変数や config 切替で）。

### 方針C（`ETag` 対応）

- 方針 B に加え、メタデータ JSON の SHA-256 を `ETag` に出力。
- `If-None-Match` を見て `304 Not Modified` を返すロジックを追加。
- 帯域節約とメタデータ整合性検知の両立。

### 方針D（`Last-Modified` ベース）

- `buildProviderMetadata` 呼び出し時に「メタデータの実体タイムスタンプ」を context から渡し、`Last-Modified` を返す。
- 設定変更時に運用者がタイムスタンプを更新する責務になる。`ETag` より運用が煩雑。

判断材料:

- PoC 用途では方針 A で十分。`ETag` は本番志向の利用者向けに後付け可能（方針 C への昇格パス）。
- `ProviderConfig` 拡張（方針 B）は鍵ローテーション運用に直結するため、`signing-key-rotation-operations.md` のタスク化と連動して検討するのが筋。
- `Last-Modified` は実用上 `ETag` 以下の利便性。本リポジトリでは採用見送りが妥当。

## 8. タスク案

- [ ] `routes/discovery.ts` に `Cache-Control: public, max-age=3600` を追加（方針A）。
- [ ] `packages/cli/src/frameworks/hono/templates.ts` の Discovery テンプレートにも同じヘッダを追加。
- [ ] `discovery.test.ts` / 統合テストに「Discovery レスポンスに `Cache-Control: public, max-age=3600` が含まれる」アサーションを追加。
- [ ] （方針B採用時）`ProviderConfig.discoveryCacheMaxAgeSeconds?: number` を追加し、context 経由でルートが参照できる経路を整備。
- [ ] （方針C採用時）`ETag` 計算ロジックを `routes/discovery.ts` に追加し、`If-None-Match` 検証で `304` を返すケースをテスト化。
- [ ] `study-material/signing-key-rotation-operations.md` のタスク案に「ローテーション時の Discovery `max-age` 短縮運用」を追記提案。
- [ ] `study-material/jwks-endpoint-comprehensive.md` §3.4 と整合する `max-age` 値を採用したことを相互参照リンクで明示。
