# Pairwise Subject Identifier（PPID）実装の検討

## ステータス

🟢 拡張機能 / 未着手（Basic OP 必須ではない）

## 1. このトピックで確認したいこと

- OpenID Connect Core 1.0 §8 が定める **Pairwise Subject Identifier**（PPID、相関防止のための RP ごと別 `sub`）の本リポジトリへの導入可否と方針を整理する。
- 既存の `study-material/sub-stability-and-subject-types.md` は「`sub` の安定性」と「現在の `public` 広告との整合性」を扱い、pairwise については「方針 C（拡張）」として後続ロードマップに送られている。本ファイルは pairwise を**独立トピック**として実装方針・タスク粒度まで掘り下げる。
- 同じ仕様説明（`sub` の安定性要件など）は繰り返さない。共通部分は `sub-stability-and-subject-types.md` を参照。

## 2. 関連する仕様・基準

`sub` の一般的な安定性・255 ASCII 文字制限・`subject_types_supported` の広告意義などは `sub-stability-and-subject-types.md` を参照。本トピック固有の差分:

### 2.1 OIDC Core 1.0 §8.1 — Pairwise Identifier Algorithm

- `subject_types_supported` に `"pairwise"` を含めて広告する場合、OP は **RP（sector）ごとに異なる `sub` を返し、かつ同一 sector 内では安定**でなければならない。
- 推奨計算式（§8.1 informative）:
  - `sub = Base64URL(SHA-256(sector_identifier || local_account_id || salt))`
  - `sector_identifier`: クライアントの `sector_identifier_uri` のホスト部、または未指定時は `redirect_uris` 全てが属するホスト部。
  - `salt`: OP 全体で 1 つ、シークレットとして安全に保管。
- `sub` の長さ制限（255 ASCII）を遵守する必要があるため、SHA-256 をそのまま 64 hex に展開せず Base64URL 等で短くする実装が一般的。
- アルゴリズムは MUST ではなく "MAY"（自前の決定論的・collision-resistant な実装でも可）だが、上記が広く採用されている。

### 2.2 OIDC Core 1.0 §8.2 — Sector Identifier の決定

- クライアントメタデータ `sector_identifier_uri` が設定されていれば、その URI のホストを sector とする。
- 未設定時は `redirect_uris` の全 URI のホストが同一であることを確認し、そのホストを sector とする。
- 複数ホストが混在しているクライアントは `sector_identifier_uri` を **MUST 設定**しなければならない（さもなければ登録拒否）。
- `sector_identifier_uri` は HTTPS で取得でき、JSON 配列形式のクライアント `redirect_uris` を含むことを **OP が事前検証** する責務（§8.2 Sector Identifier Validation）。

### 2.3 UserInfo / ID Token の `sub` 一致

- 同一クライアント（同一 sector）に対しては、ID Token と UserInfo の `sub` が一致する MUST（OIDC Core §5.3.2）。これは public/pairwise 共通。
- 異なるクライアント間（pairwise 設定下）は当然 `sub` が異なる。RP は他 RP の `sub` と一致しないことを前提に動作する。

### 2.4 ハイブリッド対応（`public` と `pairwise` の混在）

- `subject_types_supported: ["public", "pairwise"]` を広告すると、クライアントは登録時に `subject_type` を選択できる。
- 既存 `public` ユースケースを壊さないためには **per-client 設定**が必要（クライアントメタデータに `subject_type: "public" | "pairwise"`）。
- 静的クライアント登録ベースの本リポジトリでは、`RegisteredClient` に `subjectType` フィールドを追加する形が筋。

## 3. 参照資料

- OpenID Connect Core 1.0 §8 — https://openid.net/specs/openid-connect-core-1_0.html#SubjectIDTypes
  - §8.1 Pairwise Identifier Algorithm（推奨実装の informative 例）
  - §8.2 Sector Identifier Validation
- OpenID Connect Discovery 1.0 §3 — `subject_types_supported` の広告
- OpenID Connect Dynamic Client Registration 1.0 §2 — `sector_identifier_uri` / `subject_type` のクライアントメタデータ
- 本リポジトリ内: `study-material/sub-stability-and-subject-types.md`（`sub` 安定性の基盤論点。本ファイルは pairwise への差分）

## 4. 現在の実装確認

- `packages/sample/src/oidc-provider/routes/discovery.ts:32`: `subjectTypesSupported: ['public']` を静的設定。pairwise は広告していない。
- `packages/core/src/token-response.ts`: `subject` を引数で受け取り、そのまま `idTokenPayload.sub` / UserInfo へ流す。pairwise 派生ロジックは無し。
- `packages/sample/src/oidc-provider/config.ts`（`RegisteredClient`）: `subjectType` 相当のフィールド無し（`idTokenSignedResponseAlg`、`userinfoSignedResponseAlg`、`offlineAccessAllowed` のみ）。
- `sector_identifier_uri` の取得・検証ロジックも未実装。
- 結果: 現状は `subject_types_supported: ["public"]` の広告とロジックが一致しており、**仕様違反ではない**。pairwise を実装するか否かは純粋な拡張判断。

## 5. 現在の実装との差分

満たしていること:

- ✅ `public` 広告と実挙動の整合は取れている（`sub` を全 RP で同一値で返す前提）。
- ✅ `sub` の構造的バリデーション（255 ASCII）は実装済み（`id-token.ts` validatePayload）。

不足／確認が必要なこと:

- 🔴 **pairwise 未対応**: Basic OP 必須ではないため仕様違反ではないが、相関防止が要件になる PoC（B2C・プライバシー重視サービスの検証）では不足。
- 🔴 **per-client `subject_type` 設定経路が無い**: `RegisteredClient` 拡張が必要。
- 🔴 **PPID 派生関数が無い**: `core` に `derivePairwiseSubject(localSub, sectorIdentifier, salt)` 相当の純関数を置くのが筋。
- 🔴 **`sector_identifier_uri` の取得・検証が無い**: 静的クライアント登録ベースの本リポジトリでは、起動時または登録時に検証する設計が必要。
- 🟡 **salt の管理経路が無い**: PPID の salt は OP シークレットであり、漏洩すると pairwise が事実上 public 化する。`ProviderConfig` への投入経路と、ローテーション戦略（鍵ローテーションと同様の旧 salt 残存）が要る。

セキュリティ観点:

- **salt 漏洩リスク**: PPID の salt が漏れると攻撃者がオフライン辞書攻撃で `local_account_id` を逆算可能。少なくとも 32 byte のランダム値を環境変数 / シークレットマネージャから注入する設計が必要。
- **salt ローテーション**: salt を変えると全 RP に対する `sub` が変わり、RP 側のユーザー識別が破綻する。原則として **不変**。万が一の漏洩時は影響範囲全クライアントで `sub` 再構築 → サイレント移行不能のため、salt は鍵ローテーションより厳格に守る必要がある。
- **`sector_identifier_uri` 取得時の SSRF 防止**: 起動時 / 登録時の HTTP fetch でプライベートネットワークへのアクセスを防ぐ必要がある（本リポジトリは Web 標準 fetch を使うため、URL ホスト検証を加える設計）。

## 6. 改善・追加を検討する理由

価値:

- **プライバシー保護 PoC が可能**: B2C IdP の PoC で「複数 RP に渡って同一ユーザーが追跡されないこと」を体感できる。これは Conformance Suite の Phase 2/3（pairwise OP 認定）にも近い体験。
- **OIDC 仕様への完全対応**: `subject_types_supported: ["public", "pairwise"]` を広告できると、OP として「両モードを使い分けられる」シグナルになる。Fidelity 軸の強化。
- **Basic OP 認定への影響なし**: Basic OP は `public` のみで通過するため、pairwise 追加は認定取得を阻害しない。
- **既存実装への影響が局所的**: `token-response.ts` が `subject` を受け取る箇所の手前で sub 変換するため、core の大半は変更不要。

導入難易度:

- 🟡 **中**: 純関数（`derivePairwiseSubject`）は実装容易だが、`sector_identifier_uri` 検証は HTTP fetch + JSON 解析が必要で、ストア契約（`RegisteredClient` 拡張）にも触る。
- 🟢 **既存設計と整合**: resolver パターン（`AcrResolver` など、外部から injection）と同じ哲学で `SubjectResolver`（または `PairwiseSubjectStrategy`）を追加できる。

実装しない場合のリスク:

- 「OIDC 仕様の中核機能の片方が無い」状態が続く。Conformance Suite で pairwise OP プロファイルを試したい利用者は他 OSS（Keycloak、Authlete 等）に流れる。
- B2C ユースケースの PoC が成立しにくく、本リポジトリの想定ユーザー層（SME 向け IDaaS 移行支援）に対するファネル力が弱まる（ただし `RELEASE-v0.x-scope.md` では先端仕様は v0.x に含めない方針なので、v0.x のリスクではない）。

## 7. 実装方針の候補

### 方針A（最小・純関数のみ追加）

- `packages/core/src/pairwise-subject.ts` に `derivePairwiseSubject(localSub, sectorIdentifier, salt) → Promise<string>` を追加。
- SHA-256 + Base64URL で実装（Web Crypto API）。
- 単体テストで決定論性・コリジョン耐性をカバー。
- 利用者は自前で「クライアント設定 → sector 解決 → derive 呼び出し」を行う。

### 方針B（中量・resolver パターン）

- 方針A に加え、`SubjectResolver` インターフェースを追加:
  ```ts
  interface SubjectResolver {
    resolve(localSub: string, clientId: string): Promise<string>;
  }
  ```
- `token-response.ts` / `userinfo.ts` に optional な resolver 注入経路を作る。
- 利用者は `SubjectResolver` を実装し、内部で `subject_type` に応じて pairwise / public を分岐させる。
- `RegisteredClient` 拡張は CLI テンプレート側で扱い、core は subject_type を知らない設計を維持。

### 方針C（フル統合・`subject_types_supported` 自動広告）

- 方針 B に加え、`RegisteredClient` に `subjectType` / `sectorIdentifierUri` を追加。
- `ProviderConfig.pairwiseSalt: string` を追加。
- 起動時 / 登録時に `sector_identifier_uri` の HTTP fetch + 検証ロジックを実装。
- Discovery の `subject_types_supported` を「登録クライアントの subjectType 集合」から自動導出。
- CLI テンプレートに pairwise クライアント例を追加。

### 方針D（現状維持 + ドキュメント）

- pairwise を実装せず、`study-material/sub-stability-and-subject-types.md` の方針 C をそのまま保留。
- `RELEASE-v0.x-scope.md` の後続ロードマップに pairwise を明示追加（現状はリスト外）。

判断材料:

- 本リポジトリは「先端仕様より SME 向け検証ツール」を v0.x 戦略にしているため、方針 D が短期的には合理的。
- ただし方針 A（純関数のみ）は実装コスト極小で将来の方針 B/C への足がかりになる。
- 方針 C は `sector_identifier_uri` 取得の SSRF 防御まで考慮すると Tier C（本番ハード）に近づくため慎重に。

## 8. タスク案

- [ ] 方針 A / B / C / D のいずれを採るか人間が判断する。
- [ ] 方針A以上を採る場合:
  - [ ] `packages/core/src/pairwise-subject.ts` に `derivePairwiseSubject` を実装（TDD: 決定論性・collision・salt 影響のテストを先行）。
  - [ ] `packages/core/src/index.ts` から関数をエクスポート。
- [ ] 方針B以上を採る場合:
  - [ ] `SubjectResolver` インターフェースの型定義と注入経路を `token-response.ts` / `userinfo.ts` に追加。
  - [ ] `userinfo.ts` の `sub` 経路が `SubjectResolver` 通過後の値で動くことをテストでカバー。
- [ ] 方針C採用時:
  - [ ] `RegisteredClient` 拡張（`subjectType` / `sectorIdentifierUri`）と CLI テンプレートの更新。
  - [ ] `sector_identifier_uri` の HTTP fetch + JSON 検証（SSRF 防止のホスト allow-list を含む）を実装。
  - [ ] `ProviderConfig.pairwiseSalt` の投入経路と、欠落時の起動エラー化。
  - [ ] Discovery の `subject_types_supported` 自動導出ロジック。
- [ ] `sub-stability-and-subject-types.md` の方針 C を「本ファイルに移管済み」と相互参照リンクで明示。
- [ ] `RELEASE-v0.x-scope.md` の後続ロードマップに pairwise を追記提案（v0.x 含めない方針は維持）。
