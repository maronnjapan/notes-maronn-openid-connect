# Experimental 機能のタスク文書と昇格レビュー

このディレクトリは、`@maronn-openid-connect/experimental` に入る機能の仕様検討文書と、
その機能を experimental から外してよいか（昇格させてよいか）を判断するための
昇格レビューの置き場である。

## ディレクトリ構成

- `<feature-id>/` — 仕様検討中の機能。`specification.md` / `sources.md` /
  `understanding-guide.md` / `review-log.md` / `state.yaml` を置く
- `done/<feature-id>/` — 実装が main に入った機能。文書一式をそのまま移動する
- `(done/)<feature-id>/promotion-review/` — 昇格レビューパケット（後述）

## 昇格レビューの仕組み

昇格の判断は **人間のレビュアーが行う**。ツール（`scripts/experimental-review/`）は
判断材料を集めて提示するだけで、合否判定はしない。

### なぜパケットが要るのか

experimental 機能の実体は `packages/experimental/src/<feature-id>/` だけでは完結しない。
CLI の `--enable <feature-id>` が生成コードへ注入する部分にも実装が広がっており、
生成コード（`samples/*` の `src/oidc-provider` など）では他機能のコードと混ざるため、
「どこからどこまでがこの機能の実装か」を目視で追うのは難しい。

パケットはこれを解決する。CLI generator をデフォルト構成（`default-op`）と
`--enable <feature-id>` あり（`with-<feature-id>`）の 2 通りで実行してその差分を取ることで、
**生成コードのうちこの機能が寄与した部分だけを過不足なく切り出して提示する**。
あわせて、experimental 本体・CLI 統合・サンプル・E2E・ドキュメントの所在を 1 枚の地図にまとめる。

### 使い方

```bash
# パケットの生成・更新（機能ごと）
pnpm review:experimental par

# パケットが今の実装と一致しているかの検証
pnpm review:experimental par --check

# 実装済みの experimental 機能すべて
pnpm review:experimental --all
pnpm review:experimental --all --check

# 機能ごとの状況（パケット有無・判断・実装との一致）の一覧
pnpm review:experimental status
```

対象の機能一覧は CLI 側の定義（`packages/cli` の `EXPERIMENTAL_FEATURES`）が唯一の情報源で、
新しい experimental 機能を CLI に追加すればこのツールの対象にも自動的に入る。

### パケットの中身

```
promotion-review/
  README.md          レビュー対象の地図（実装・テスト・ドキュメントの所在）と推奨手順
  generated-code/    フレームワークごとの生成コード差分（差分が同一のものは 1 ファイルに集約）
  decision.md        判断記録。人間だけが書く。ツールは上書きしない
```

`README.md` と `generated-code/` はツールが再生成のたびに作り直す機械生成物なので、
手で編集しない。パケットはコミットする。コミットされた Markdown なので、
`.review/` のレビューコメントの仕組み（ルートの CLAUDE.md 参照）をそのまま使って
パケット上にコメントを残せる。

### 判断の記録（Go サイン）

レビューを終えたら `decision.md` の front matter を書き換える。

```yaml
decision: go            # go / no-go / hold / pending
decided_at: 2026-08-10  # 判断日
decided_by: maronn
reviewed_commit: abc123 # `--check` が通った時点のコミット SHA
```

チェックリスト（昇格条件・レビュー完了）を埋めてから判断する。
ここでの `go` は「experimental から外してよい」という判断の記録であって、
昇格作業そのもの（core への移植・experimental からの削除）は別タスクとして行う。

### 鮮度の考え方

パケットは生成時点のスナップショットで、実装や CLI テンプレートが変わると `--check` が
失敗するようになる。機能の足跡に影響する変更を入れたときは、該当機能のパケットを
再生成して同じコミットに含める。判断済みの機能でパケットが動いた場合は、
再生成して git diff で「何が変わったか」を確認し、判断を維持できるか見直す。
