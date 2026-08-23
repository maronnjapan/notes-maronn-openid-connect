# 運用観点のヘルス／レディネス／スタートアップ確認エンドポイント

## 1. タイトル

OP を OSS として配布する際に、コンテナ／Kubernetes／PaaS 等のインフラから「OP が起動済み・受け入れ可能・依存リソースに到達可能」を確認するためのヘルスチェック類のエンドポイント設計方針。

## 2. このトピックで確認したいこと

- Basic OP の **仕様上の必須機能ではない**（OIDC / OAuth 2.1 にヘルスチェックの定義はない）が、本リポジトリのコンセプト「PoC 開発者・本番導入を見据える開発者が爆速で検証できる」を満たすためには、運用面の入口を最小限提供すべきか整理する。
- 既存ファイル: `study-material/audit-logging-and-observability.md` / `audit-logging-observability.md` で観測性は扱われているが、**「ヘルスチェック専用のエンドポイント」**は別軸として整理されていない。`study-material/signing-key-rotation-operations.md` で「鍵の状態」は触れているが、ヘルスチェック面ではない。
- リポジトリの哲学（Web 標準のみ、外部依存なし）に沿った形で、どこまでを core に持たせ、どこからを cli 生成テンプレートや sample 側に置くかを判断する。

## 3. 関連する仕様・基準

OIDC / OAuth の一次仕様には該当項目なし。本トピックは「OSS としての運用容易性」軸であり、以下を参考にする。

### 3.1 Kubernetes プローブの慣行

- `livenessProbe`: プロセスが生きているかの判定。失敗 → コンテナ再起動。
- `readinessProbe`: トラフィックを受け入れ可能か。失敗 → サービスから外す（再起動はしない）。
- `startupProbe`: 起動中の判定。起動が遅いコンテナの初期化完了を待つ。
- 一般的なパス例: `/healthz`, `/readyz`, `/livez`, `/startupz`。

### 3.2 RFC 7807 / RFC 9457（Problem Details for HTTP APIs）

- ヘルスチェックの失敗応答に構造化エラーを返す場合の標準。Basic OP のエラーレスポンス（`study-material/error-response-cross-endpoint.md`）とは別系統だが、設計を揃えると一貫性が増す。

### 3.3 OIDC Discovery との関係

- Discovery エンドポイント（`/.well-known/openid-configuration`）も「200 OK が返れば OP は起動している」という疑似ヘルスチェックに使われがちだが、**目的が異なる**（クライアント向けのメタデータ供給）ため、本番運用では専用エンドポイントを別途用意する方が望ましい。
  - Discovery を ヘルスチェックに流用すると Cache-Control / CDN キャッシュと干渉する（`study-material/done/discovery-cache-control-and-etag.md`）。

### 3.4 信頼できる二次資料

- Google SRE Book / Kubernetes 公式ドキュメントの Probes 章。
- OpenTelemetry の Health Check Semantic Conventions（draft）。

## 4. 参照資料

- Kubernetes Probes — https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/
- RFC 9457 (Problem Details for HTTP APIs) — https://datatracker.ietf.org/doc/html/rfc9457
- 本リポジトリ既存: `study-material/audit-logging-and-observability.md`, `study-material/signing-key-rotation-operations.md`, `study-material/done/discovery-cache-control-and-etag.md`
- 関連 OSS 実装の参考（idea のみ、本リポジトリでは外部依存禁止のため直接利用しない）: Keycloak の `/health/live` `/health/ready`、ory hydra の `/health/alive` `/health/ready`

## 5. 現在の実装確認

- core 側（`packages/core`）: ヘルスチェック関連のエンドポイント／関数は存在しない。
- cli 生成テンプレート（`packages/cli`）: 同上、ヘルスチェック生成オプションは無い。
- sample（`packages/sample`）: 同上。`fetch` で起動確認するなら `/.well-known/openid-configuration` への GET を都度行うことになる。
- Discovery `packages/core/src/discovery.ts`: 健全性表現は含まない（仕様通り）。

## 6. 現在の実装との差分

満たしていること:

- ✅ Basic OP 必須機能には抜けがない（OIDC/OAuth 仕様にヘルスチェックの要件は無い）
- ✅ Discovery エンドポイントが事実上の「起動確認」の役割を果たせる（ただし本来用途ではない）

不足・確認が必要なこと:

- 🟡 **K8s / コンテナ運用のための専用エンドポイント不在**: 本番投入を見据える利用者は自分でハンドラを増設する必要がある。最小限の `/healthz` / `/readyz` テンプレートが cli で生成できると体験が良い。
- 🟡 **依存リソースの状態確認指針が無い**: Authorization Code Store, Refresh Token Store, JWKS（署名鍵）は OP の動作に必須だが、これらの health 判定方法（store の ping 関数、署名鍵が in-memory にロード済みか）が `study-material/resolver-and-store-contract.md` でも触れられていない。
- 🟡 **`startup` 段階の鍵ロード待機**: `study-material/signing-key-rotation-operations.md` と関連。鍵生成・読込が非同期な利用者実装で、`readiness` までは鍵未ロードでリクエストを受けない、という整理が無い。
- 🟢 **ライブラリ責務の境界**: ヘルスチェックは「フレームワーク（Hono / express 等）に強く依存する」要素であり、core に直接ハンドラを置くと Web 標準 API のみで完結する哲学とぶつかる。**core は判定関数（純粋関数）を提供し、ハンドラ実装は cli / sample / 利用者側**という分離が現実的。

## 7. 改善・追加を検討する理由

- 本リポジトリは「PoC → 本番移行のブリッジ」を標榜するため、運用面の入口（ヘルスチェック）が空白だと「PoC では動くが本番投入には自前で作り込みが必要」という体験ギャップが生じる。
- 利用者が cli で生成したコードに `/healthz` `/readyz` テンプレートが含まれていれば、Kubernetes / Cloud Run / Fargate へのデプロイが「即動く」状態になり、Speed の差別化軸（CLAUDE.md 記載）にも貢献する。
- 実装しない場合のリスク: 本番投入時に各利用者が独自にハンドラを書き、ヘルス判定基準もバラバラになる。OSS として再現性のあるリファレンスが失われる。
- 一方で、core に過剰実装すると外部依存なし／Web 標準 API のみという原則から外れる懸念がある。**core は「健全性判定の純粋関数」「Store 契約への ping インターフェース」のみ提供**し、ハンドラ自体は cli 生成または利用者側に委ねる方針が整合的。

## 8. 実装方針の候補

- 方針A（やらない）: Basic OP 仕様外の運用機能はスコープ外として明記し、利用者責務とする。`study-material/RELEASE-v0.x-scope.md` の「やらないこと」セクションに追加する。
- 方針B（core に判定関数のみ、ハンドラは cli 生成）: 以下のような純粋関数を core に置く。
  - `checkSigningKeyAvailability(jwks: JwksProvider): Promise<HealthStatus>`
  - `checkStoreReady(store: AuthorizationCodeStore | RefreshTokenStore): Promise<HealthStatus>`
  - `aggregateHealth(checks: HealthCheck[]): OverallStatus`
  - cli テンプレートで `/healthz`（liveness：プロセス生存だけ）と `/readyz`（readiness：上記関数を集約）を生成する。
- 方針C（cli 生成のみで対応）: core にロジックを置かず、cli 生成のテンプレートに「`/healthz` は常に 200、`/readyz` は store の存在確認を行う」最小ハンドラを含める。
- 方針D（Store 契約に `isReady?()` を追加）: `study-material/resolver-and-store-contract.md` 側の Store 契約インターフェースに optional な `isReady()` を追加し、利用者が任意実装。Readiness 判定で集約する。Basic OP デフォルト挙動には影響しない opt-in 拡張。

最終判断（A〜D のどれを採るか、また B のシグネチャの粒度）は人間が行う。

## 9. タスク案

- [ ] `RELEASE-v0.x-scope.md` または本ファイル付近に「ヘルスチェックは Basic OP 仕様外、本リポジトリでの提供範囲」決定事項を記録
- [ ] core に置く判定関数の有無・粒度を decision として記録（方針 B 採用時のシグネチャドラフト）
- [ ] cli 生成テンプレートに `/healthz` `/readyz` 最小ハンドラを含めるかの判断と、含める場合の生成ファイルパス決定
- [ ] `study-material/resolver-and-store-contract.md` に `isReady?()` 追加可否を追記
- [ ] `study-material/signing-key-rotation-operations.md` の「鍵ロード前の readiness」記述追加
- [ ] sample 側で readiness 確認の参考実装が必要かの判断（不要なら明記）
