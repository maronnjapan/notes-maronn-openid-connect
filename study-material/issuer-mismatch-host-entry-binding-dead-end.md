# issuer と異なるホストで開始したフローが transaction-binding で行き止まりになる（内部リダイレクト origin 統一の後続論点）

## 1. タイトル

内部リダイレクトの origin を `config.issuer` に統一した変更（`study-material/done/generated-op-internal-redirect-origin-derivation.md`、実装済み）により、`/authorize` を issuer と異なるホストで受けたフローは `/login` へのリダイレクトで issuer ホストへ移る。
transaction-binding を有効にした構成では、束縛 Cookie が `/authorize` を受けたホストに対して発行される（host-only Cookie）ため、issuer ホスト側の `/login` にはこの Cookie が届かず、フローは毎回「このブラウザで開始されたトランザクションではありません」の 400 で止まる。
fail-closed 自体は意図どおりだが、失敗が遅く（トランザクションを保存した後）、原因（ホストと issuer の不一致）と無関係な診断メッセージになる点を扱う。

## 2. このトピックで確認したいこと

- issuer と異なるホストからの流入が現実に起きる構成（`*.workers.dev` とカスタムドメインの併存、プロキシの別名、設定ミス）で、現在の挙動がどう見えるか
- `/authorize` の時点でホストと issuer の不一致を検出して早期に失敗（またはログで警告）すべきか
- これは修正すべき欠陥か、fail-closed の許容範囲として文書化で足りるか（判断が割れうるため、方針は未確定）

## 3. 関連する仕様・基準

- **RFC 9700 §2.1 / OIDC Discovery 1.0 §3**: OP 自身の URL の真実の情報源は issuer 設定である。この方向の変更自体は正しい
- **RFC 6265 §8.5 / §8.6**: Cookie はホスト単位で隔離される。`/authorize` を受けたホストと `/login` のホストが違えば、束縛 Cookie は構造的に届かない

前提となる内部リダイレクト origin の検討は `study-material/done/generated-op-internal-redirect-origin-derivation.md`、束縛 Cookie の設計は `study-material/done/auth-transaction-user-agent-binding.md` を参照。
本ファイルは両者の合流点で新しく生じた失敗モードだけを扱う。

## 4. 参照資料

- RFC 9700 OAuth 2.0 Security Best Current Practice §2.1 — https://www.rfc-editor.org/rfc/rfc9700.html
- RFC 6265 HTTP State Management Mechanism §8.5 — https://www.rfc-editor.org/rfc/rfc6265#section-8.5
- 本リポジトリ内: 上記 2 つの done ファイル、`study-material/issuer-multitenancy-and-subpath.md`（issuer 構成の一般論）

## 5. 現在の実装確認

- `packages/cli/src/frameworks/hono/templates.ts`: authorize / login ルートは `new URL('/login', config.issuer)` などで issuer origin の絶対 URL へリダイレクトする（実装済みの変更）
- 同テンプレートの transaction-binding: `/authorize` のレスポンスで束縛 Cookie（`Path=/`、`Domain` 指定なしの host-only）を設定し、`/login` / `/consent` で `rejectUnboundTransaction` が検証する
- ホスト A（≠ issuer ホスト B）で `/authorize` を受けた場合の流れ: 検証・トランザクション保存・Cookie 設定（ホスト A 宛）まで成功し、`https://B/login` へ 302。ブラウザは B へ Cookie を送らないため、binding 有効時は 400 で停止する。`/authorize` にホストと issuer の不一致を検出する処理は無い
- 生成 conformance テストの cross-host ケースは Cookie を手動で持ち回るため、この実ブラウザ挙動は検証範囲外

## 6. 現在の実装との差分

満たしていること:

- 内部リダイレクトが攻撃者由来のホストへ向かうことはなくなった（変更の主目的は達成）
- binding 無効の構成では、issuer ホストへ移ったフローはそのまま完走できる

確認が必要なこと:

- 🟡 binding 有効かつ「流入ホスト ≠ issuer ホスト」の構成で、フローが毎回トランザクション保存後に 400 で止まる。エラー文言はブラウザ起因を示唆し、実際の原因（ホスト不一致）へ導かない
- 🟡 失敗のたびにトランザクションストアへエントリが 1 件残る（TTL で消えるが、無駄な書き込みが続く）

## 7. 改善・追加を検討する理由

fail-closed の方向は維持したまま、失敗を早く・正しい診断で返せる余地がある。
一方で「issuer と異なるホストで OP を受けること」自体が構成上の誤りであり、検出を増やすより文書化で足りるという判断もありうる。
どちらを採るかで実装の要否が変わるため、現時点ではタスク化しない。

## 8. 実装方針の候補

- **方針 A**: `/authorize` でリクエストホストと issuer ホストの不一致を検出し、トランザクションを保存せずに OP 自身のエラーページ（構成不一致を示す文言）を返す
- **方針 B**: 検出はするが失敗にはせず、起動時または初回検出時に警告ログを出す（マルチホスト運用を許容）
- **方針 C**: コードは変えず、README とデプロイガイドに「issuer と一致するホストだけで OP を受けること（binding 有効時は必須）」を明記する

方針判断には、`*.workers.dev` 併存のような正当なマルチホスト構成をどこまで支援するかの製品判断が要る。

## 9. タスク案

まだタスク化しない。
方針（A / B / C）が決まった時点で、検出位置・エラー文言・conformance テスト（実ブラウザ相当の Cookie 挙動を再現するか）を含めて切り出す。
