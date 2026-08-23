# Introspection の `token_type` に refresh token 用の非標準値 `refresh_token` を返している問題（RFC 7662 §2.2 / RFC 6749 §7.1）

## ステータス

🟠 High / 未着手

## 1. このトピックで確認したいこと

Token Introspection（RFC 7662）のレスポンスに含める `token_type` メンバーが、
リフレッシュトークンをイントロスペクトしたときに `"refresh_token"` という値を返している。
`token_type` は RFC 6749 §7.1 で定義される「アクセストークンの型」（`Bearer` など）を指すメンバーであり、
`refresh_token` はそこに存在しない値である。この値をそのまま返すと、RFC 7662 準拠のリソースサーバ／
ゲートウェイが `token_type` を RFC 6749 §7.1 の型として解釈したときに未知の値となり、相互運用性を損なう。

本ファイルは、この `token_type` の値が仕様上どうあるべきかを整理し、リフレッシュトークンの
イントロスペクションレスポンスで `token_type` をどう扱うか（省略する／別メンバーで型を示す）を検討する。

> 関連既存ファイル：
> - `study-material/done/introspection-caller-authorization-and-disclosure.md` は「誰にどこまで開示するか」の
>   呼び出し元認可と情報開示範囲を扱い、`token_type` の**値の正当性**は扱っていない。
> - `study-material/ext-jwt-introspection-response-rfc9701.md` は JWT 形式のイントロスペクションレスポンス（RFC 9701）を扱い、
>   本トピック（プレーン JSON の `token_type` 値）とは別物。
> 本ファイルは **`token_type` メンバーの値が RFC 6749 §7.1 の型集合に反している点**という固有差分のみを扱う。

## 2. 関連する仕様・基準

- **RFC 7662 §2.2（Introspection Response）**:
  > `token_type` OPTIONAL. Type of the token as defined in Section 7.1 of OAuth 2.0 [RFC6749].
  - すなわち `token_type` は RFC 6749 §7.1 で定義される**アクセストークンの型**を意味する。
- **RFC 6749 §7.1（Access Token Types）**: `token_type` は `Bearer`（RFC 6750）、`mac` 等、
  アクセストークンの提示方法を示す型であり、"refresh_token" という値は定義されていない。
- **RFC 7662 のレスポンスモデル**: リフレッシュトークンは「アクセストークンではない」ため、
  `token_type`（アクセストークンの提示型）を返す意味的な根拠が無い。リフレッシュトークンに対しては
  `token_type` を**省略する**のが最も素直で、種別を示したい場合は別途 `scope` / `aud` / 独自メンバーで表現する。
  RFC 7662 は `active` 以外のトップレベルメンバーをすべて OPTIONAL としているため、省略は完全に準拠。

## 3. 参照資料

- RFC 7662 §2.2（Introspection Response, `token_type`）: https://www.rfc-editor.org/rfc/rfc7662#section-2.2
- RFC 6749 §7.1（Access Token Types）: https://www.rfc-editor.org/rfc/rfc6749#section-7.1
- RFC 6750（Bearer Token Usage, `token_type=Bearer`）: https://www.rfc-editor.org/rfc/rfc6750

## 4. 現在の実装確認

- `packages/core/src/introspection.ts`
  - レスポンス型 `IntrospectionResponse`（`:76-89` 付近）で `token_type?: 'Bearer' | 'refresh_token'` と定義している。
    `'refresh_token'` を型レベルで許容してしまっている。
  - `buildAccessTokenResponse`（`:104-120` 付近）: `token_type: 'Bearer'`（妥当）。
  - `buildRefreshTokenResponse`（`:122-134` 付近）: `token_type: 'refresh_token'`（**非標準値**）。
- 各 sample の `conformance.test.ts`（CLI 生成）でこの挙動が固定されている想定
  （例: introspection のリフレッシュトークンレスポンス期待値に `token_type: 'refresh_token'` が入っている）。
  → 変更時は `packages/cli` のテンプレート側 conformance テスト生成コードを更新する必要がある。

## 5. 現在の実装との差分

- **満たしていること**
  - アクセストークンの `token_type: 'Bearer'` は RFC 6750 準拠で正しい。
  - `active` フラグや `exp` / `iat` / `sub` / `scope` 等の返却は概ね RFC 7662 準拠。
- **不足している可能性があること**
  - リフレッシュトークンの `token_type: 'refresh_token'` は RFC 6749 §7.1 に存在しない値であり、
    RFC 7662 §2.2 の定義（"as defined in Section 7.1"）に反する。
- **相互運用性の観点**
  - `token_type` を RFC 6749 §7.1 の型として分岐処理するクライアント／RS では未知の値になり、
    実装によっては拒否・警告・誤判定につながる。
- **Basic OP として確認すべきこと**
  - Introspection は Basic OP の必須要件ではない（拡張）。ただし OSS として提供する以上、
    RFC 7662 準拠を謳う endpoint は準拠した値を返すべき。

## 6. 改善・追加を検討する理由

- **Fidelity（仕様忠実性）**: 本リポジトリの差別化軸である「忠実性」に直結する。RFC 準拠を掲げる endpoint が
  非標準値を返すのは信頼性シグナルを損なう。
- **相互運用性**: 商用 RS / API Gateway が RFC 7662 の `token_type` を RFC 6749 型として扱う実装は珍しくない。
- **導入しやすさ**: 変更は `buildRefreshTokenResponse` から `token_type` を落とすだけで、実装リスクは小さい。
  ただし conformance.test.ts の期待値変更を伴うため、CLI テンプレート側の更新が必須（本リポジトリの契約テスト方針）。
- **実装しない場合のリスク**: リフレッシュトークンのイントロスペクション結果を機械処理する連携先で
  誤動作が起きうる。標準外の値に依存した利用者コードが増えると後方互換の足かせになる。

## 7. 実装方針の候補

判断材料の整理（最終判断は人間）。

- 方針A（推奨）: リフレッシュトークンのレスポンスから `token_type` を**省略**する。
  - RFC 7662 で `token_type` は OPTIONAL なので省略は完全準拠。
  - 型定義を `token_type?: 'Bearer'` に狭める。
  - トークン種別を機械可読にしたい利用者向けには、別トピックで RFC 9701（JWT introspection）や
    独自メンバーの是非を検討（本ファイルの範囲外）。
- 方針B: リフレッシュトークンでは `token_type` を返しつつ、値は返さない（＝A と実質同じ）。
- 方針C（非推奨）: 現状維持。RFC 準拠を諦める代わりに後方互換を優先。OSS の信頼性方針と矛盾するため非推奨。

## 8. タスク案

- [ ] `introspection.test.ts` に「リフレッシュトークンのイントロスペクションで `token_type` を含まない」テストを先行追加（Red）
- [ ] `IntrospectionResponse` の `token_type` を `'Bearer'` のみに狭め、`buildRefreshTokenResponse` から `token_type` を削除（Green）
- [ ] `packages/cli` の conformance.test.ts 生成コードを更新し、リフレッシュトークンレスポンス期待値から `token_type` を除去
- [ ] 各 sample の `conformance.test.ts` を再生成し、契約テストが通ることを確認
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test` および各 sample の conformance テストがパス
