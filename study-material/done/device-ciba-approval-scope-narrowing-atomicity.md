# device / CIBA 承認のスコープ絞り込みが 2 段階 update で行われる非 atomic 性

## 1. このトピックで確認したいこと

`--scope` 宣言時の生成 OP で、device grant と CIBA の承認処理が「承認確定（experimental 側）」と「スコープ絞り込み（生成コード側）」を別々の `store.update()` で永続化している。この 2 段階更新が、ポーリング中のトークンエンドポイントと競合したときに何が起きるかを確認する。

## 2. 関連する仕様・基準

- RFC 6749 §3.3: 付与 scope は AS のポリシーで要求より狭められる。トークンレスポンスは実際の付与内容を報告する。
- RFC 8628 §3.4-3.5: デバイスクライアントは token endpoint を継続ポーリングし、device_code は単回使用。
- CIBA Core 1.0 §10.1 / §11: auth_req_id はトークン発行の根拠であり、リプレイを防ぐ。
- 実装自身の契約: experimental の store は「認可状態の遷移と consume の単回使用が守られていればセキュリティ特性は保たれる」ことを JSDoc で前提にしている。

## 3. 参照資料

- `packages/experimental/src/ciba/verification.ts`（`approveCibaRequest`）/ `packages/experimental/src/device-authorization-grant/verification.ts`（`approveDeviceAuthorization`）
- `packages/cli/src/frameworks/hono/templates.ts` の device / CIBA `approveNarrowStep`（`--scope` 宣言時のみ生成）
- `packages/experimental/src/ciba/ciba-grant.ts` / `device-authorization-grant/device-code-grant.ts`（`store.consume()` による単回使用）
- `study-material/scope-handling-validation-and-granted-scope.md`（granted scope の一般論。本ファイルは承認永続化のタイミングに限定する）

## 4. 現在の実装確認

1. `approveCibaRequest` / `approveDeviceAuthorization` は `status='approved'`、`approvedScope=[...record.scope]`（**絞り込み前の全要求 scope**）を `store.update()` で永続化してから return する。
2. `--scope` 宣言時のみ生成される `approveNarrowStep` が、その**後で** `resolveGrantableScopes()` を適用し、`store.update(approved)` で**もう一度**保存する。
3. トークンエンドポイントは `store.consume()`（atomic 取得+削除）で `approvedScope` を読み、トークンを発行する。
4. 同梱インメモリストアの `update` は `records.set(...)` の upsert。

CD / デバイスは interval（既定 5 秒）で常時ポーリングしているため、1. と 2. の間に 3. が割り込む競合は現実的に起きる。

## 5. 現在の実装との差分

- 🔴 **スコープ昇格ウィンドウ**: 1. の直後に consume されると、`resolveGrantableScopes` が落とすはずだった scope を含むアクセストークン / ID トークンが発行される。consent 記録は絞り込み後の値になるため、記録と実発行も食い違う。`resolveGrantableScopes` は DB / KV 参照への差し替えを公式に想定した async シームなので、実運用ではウィンドウは広がる。
- 🔴 **単回使用違反**: ウィンドウ内で consume された後に 2. の `update(approved)` が走ると、upsert により consume 済みレコードが approved 状態で復活し、同じ device_code / auth_req_id で 2 本目のトークンが取れる。store 契約の「atomic consume」保証を生成コードが外から破る形になる。
- 既定（`--scope` 宣言なし）では `approveNarrowStep` が生成されないため、どちらも発生しない。

## 6. 改善・追加を検討する理由

この機能の目的自体が「`resolveGrantableScopes` にポリシーを書くこと」なので、「既定の空ポリシーでは無害」という緩和は成立しない。ポリシーを書いた利用者に限って絞り込みが破られる。また、レコード復活は experimental モジュール自身が置いた単回使用保証への違反であり、ポリシーの有無に関係なく設計として除去すべき形になっている。

## 7. 実装方針の候補

- 案 A（推奨）: `approveCibaRequest` / `approveDeviceAuthorization` に絞り込み済み `approvedScope`（または narrow 関数）を引数で渡せるようにし、`status='approved'` と絞り込み済み scope を**単一の update** で永続化する。生成コードの承認確定後の再 update を排除する。
- 案 B: 生成コード側で「絞り込み → 承認確定」の順に並べ替える。experimental の API 変更は不要だが、絞り込みが承認前の record を対象にできるよう生成コードの組み立てが複雑になる。
- どちらの場合も、experimental の実装解説（device / CIBA の ja / en）とテストの同期が必要。

## 8. タスク案

- [ ] 承認関数のシグネチャを拡張し、承認確定と絞り込みを 1 回の update に統合する（device / CIBA 両方）
- [ ] 「承認確定後にレコードを update しない」ことを契約テストまたは実装コメントで固定する
- [ ] 競合を模した単体テスト（承認中に consume が割り込むケース）を追加する

→ `tasks/p2-device-ciba-approval-scope-atomic-update.md` としてタスク化済み。
