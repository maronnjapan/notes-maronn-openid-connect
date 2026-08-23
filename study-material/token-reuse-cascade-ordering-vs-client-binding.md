# 再利用カスケード失効がクライアント所有権チェックより前に走る（別クライアントによる家族失効の踏み台）

## 1. このトピックで確認したいこと

Token Endpoint の再利用検知（authorization_code / refresh_token の `used` 検出）で、`revokeTokensByGrantId(grantId)`（同一 grant のトークン家族全失効）が、そのコード/トークンの**発行先クライアントと認証済みクライアントの一致チェックより前**に実行される。結果、認証済みの任意クライアントが「別 grant に属する使用済みトークン/コード」を提示すると、その別 grant のトークン家族を強制失効させられる。

本ファイルは、この**カスケードとクライアント所有権チェックの順序**、および「認証済み別クライアントが他 grant の失効を誘発できる」という帰結に限定する。カスケードの `revoke*` セマンティクス（mark-used vs delete）や TOCTOU 二重発行は `study-material/done/authorization-code-reuse-cascade-store-semantics.md` で、失効エンドポイントの兄弟 RT 到達は `study-material/revocation-refresh-token-family-cascade.md` で扱い済み。

## 2. 関連する仕様・基準

再利用時のトークン失効（family revocation）の共通説明は上記 2 ファイルを参照し繰り返さない。

- **RFC 9700 §4.13（Authorization Code Injection / Replay）・§4.14（Refresh Token）**（章番号は現行 RFC 9700 で要確認。コードは両方を引用）: 再利用検知時に発行済みトークンを失効することを推奨。ただし脅威モデルは「**正規クライアント**が自身のトークンを再提示する」ケースを想定しており、「別の認証済みクライアントが他 grant の失効を駆動する」ことは想定していない。
- **OAuth 2.1 draft §4.1.2（authorization_code single use）/ §4.3.1（refresh token rotation）**: single-use・rotation・再利用時失効を規定。所有権チェックとカスケードの順序までは規定しない。

つまり「再利用時に失効する」こと自体は SHOULD で妥当。論点は「**誰が**そのカスケードを引き金にできるか」という設計判断で、仕様上の明確な MUST は無い。

## 3. 参照資料

- RFC 9700 OAuth 2.0 Security Best Current Practice — https://www.rfc-editor.org/rfc/rfc9700
- OAuth 2.1 draft §4.1.2 / §4.3.1 — https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- 既存の関連記述（重複回避）: `study-material/done/authorization-code-reuse-cascade-store-semantics.md`、`study-material/revocation-refresh-token-family-cascade.md`

## 4. 現在の実装確認

`packages/core/src/token-request.ts`:

- refresh_token グラント:
  ```ts
  if (refreshTokenInfo.used) {                                  // L480
    if (refreshTokenResolver.revokeTokensByGrantId) {
      await refreshTokenResolver.revokeTokensByGrantId(refreshTokenInfo.grantId);   // L482: 家族失効
    }
    throw new TokenError(TokenErrorCode.InvalidGrant, 'Refresh token has already been used');
  }
  if (refreshTokenInfo.clientId !== authenticatedClientId) {    // L491: 所有権チェック（カスケードより後）
    throw new TokenError(TokenErrorCode.InvalidGrant, 'Refresh token was issued to a different client');
  }
  ```
- authorization_code グラント:
  ```ts
  if (authCode.used) {                                          // L581
    if (authCodeResolver.revokeTokensByGrantId) {
      await authCodeResolver.revokeTokensByGrantId(authCode.grantId);              // L583: 家族失効
    }
    throw new TokenError(TokenErrorCode.InvalidGrant, 'Authorization code has already been used');
  }
  if (authCode.clientId !== authenticatedClientId) {            // L592: 所有権チェック（カスケードより後）
    throw new TokenError(TokenErrorCode.InvalidGrant, 'Authorization code was issued to a different client');
  }
  ```

両経路とも「`used` → カスケード失効 → throw」が「クライアント一致チェック」より前。認証済みクライアント A が、クライアント B に発行された使用済みコード/RT の文字列を入手して提示すると、B の grant 家族が失効する。

## 5. 現在の実装との差分

- **満たしていること**: 再利用検知時に家族を失効する挙動（SHOULD）は実装済み。single-use / rotation のロジックも正しい。
- **確認が必要なこと（順序の是非）**:
  - 現状は「**フェイルセキュア**」寄り。使用済みトークンが漏洩している状況では、提示者が誰であれ失効するのは安全側。
  - 一方で、悪意ある**登録済み**クライアントが被害者の使用済みトークン文字列を握ると、被害者の grant 家族を任意に失効させる**グリーフィング/DoS の踏み台**になり得る（使用済みトークンの入手という前提条件は必要）。
- **セキュリティ上の観点**: これは「フェイルセキュア vs 濫用耐性」のトレードオフ。所有権チェックを先に置くと、別クライアントが漏洩した使用済みトークンを提示しても `invalid_grant` を返すだけで**漏洩した家族を失効しない**という、逆に弱い挙動になり得る。
- **相互運用性の観点**: 正常系には影響しない。
- **Basic OP として確認すべきこと**: 失効/カスケードは Basic OP 認定項目ではない。認定可否には無関係。

## 6. 改善・追加を検討する理由

- **なぜ検討するか**: 挙動が「意図した設計（フェイルセキュア）」なのか「見落とし」なのかがコード上明示されておらず、テストでも順序が固定されていない。将来のリファクタで順序が変わっても検知できない。
- **Basic OP 必須か拡張か**: どちらでもないハードニング/設計明確化。
- **導入しやすさ**: 判断が「順序を保つ」なら、テスト固定とコメント追記のみで実装変更ゼロ。「所有権を先に」に変えるなら数行の入れ替えだが、上記トレードオフの評価が必要。
- **実装しない場合のリスク**: グリーフィング踏み台の可能性が文書化・固定されないまま残る。逆に安易に順序を入れ替えると、漏洩トークンの家族失効が効かなくなる副作用がある。

## 7. 実装方針の候補（判断材料）

最終判断は人間が行う。これは**明確なバグではなくトレードオフのある設計判断**である。

- 方針A（現状維持 + 意図の明示, 有力）: 「再利用検知時は提示者に関わらず失効（フェイルセキュア）」という意図をコメントで明記し、`token-request.test.ts` で「別クライアントが使用済みトークンを提示するとカスケードが走る」ことをテスト固定。実装変更なし。
- 方針B（所有権チェックを先に）: `clientId !== authenticatedClientId` を `used` チェックより前に置く。別クライアントの提示ではカスケードを走らせない。ただし「漏洩した使用済みトークンを別クライアントが提示した場合、家族が失効されない」弱化が起きる。要トレードオフ評価。
- 方針C（折衷）: 所有権不一致でも「使用済み」なら失効は行うが、`invalid_grant` に統一しつつ、失効の実行を「所有権一致時のみ即時 / 不一致時はレート制限付き or ログのみ」に分ける。複雑化するため慎重に。

## 8. タスク案（タスク化は保留 — 設計トレードオフの判断が必要）

「フェイルセキュア維持」か「所有権優先」かは人間の判断が必要で、方針が定まっていないためタスク化しない。

- [ ] 現状のフェイルセキュア順序を「意図した設計」として維持するか、所有権優先に変えるかを人間が判断
- [ ] 判断後、`token-request.test.ts` に順序を固定するテストを追加（どちらの方針でも順序の退行を防ぐ）
- [ ] グリーフィング踏み台の緩和（レート制限等）が必要かを別途評価（`study-material/rate-limiting-and-brute-force.md` と接続）
- [ ] 挙動を変える場合は `packages/cli` テンプレート／`samples/*/conformance.test.ts` の再利用カスケード契約を更新

## 関連トピック

- `study-material/done/authorization-code-reuse-cascade-store-semantics.md` — `revoke*` の mark-used vs delete と TOCTOU。本ファイルは順序（所有権チェックとの前後）という別軸。
- `study-material/revocation-refresh-token-family-cascade.md` — 失効エンドポイントの家族到達。
- `study-material/rate-limiting-and-brute-force.md` — グリーフィング緩和の接続先。
