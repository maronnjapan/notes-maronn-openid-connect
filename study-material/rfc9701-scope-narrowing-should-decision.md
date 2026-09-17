# RFC 9701 §5 の scope 絞り込み SHOULD への態度が未記録である問題

## 1. このトピックで確認したいこと

RFC 9701（JWT Response for OAuth Token Introspection）§5 は "The AS SHOULD narrow down the scope value to the scopes relevant to the particular RS" と定める。現在の実装はこの絞り込みを行っておらず、かつ、行わないという設計判断も記録されていない。逸脱の記録または実装のどちらで応えるかを確認する。

## 2. 関連する仕様・基準

- RFC 9701 §5（datatracker 版で逐語確認済み）: 応答の `scope` を当該 RS に関係するスコープへ絞る SHOULD。
- RFC 9701 §9: RS の identity に基づいて開示データを決定する MUST。現実装はこれを audience 制限（呼び出し元不一致なら `{active:false}`）で満たすと主張している。

## 3. 参照資料

- `packages/experimental/src/jwt-introspection-response/audience.ts`（開示は all-or-nothing。全属性そのまま or `{active:false}`）
- `packages/experimental/src/jwt-introspection-response/response-jwt.ts`（「メンバーを追加・削除・改変しない」と明言）
- `tasks/experimental/done/jwt-introspection-response/specification.md`（§5 の MUST 群は網羅的に引用しているが、この SHOULD には触れていない）
- `study-material/done/introspection-caller-authorization-and-disclosure.md`（RFC 7662 §4 の claim minimization 一般論。JSON 経路・core フック側の責務として扱っており、RFC 9701 の JWT 経路は未言及）
- `study-material/done/introspection-public-client-unauthenticated-caller.md`（同じ RFC 9701 実装の認証面の問題。本ファイルは開示最小化の面に限定する）

## 4. 現在の実装確認

トークンの `aud` に載る第三者 RS が introspection を呼ぶと、全 scope・他 RS を含む `aud` リスト・`sub` 等が丸ごと開示される。scope と RS の対応表を持たないため、絞り込みの材料が現状のデータモデルに無い。

## 5. 現在の実装との差分

- 🟠 SHOULD からの逸脱自体は許容され得るが、仕様書が §5 の他の規範を網羅しながらこの 1 点だけ沈黙しており、意図的な逸脱か見落としかを後から判別できない。
- 🟢 audience 制限（呼び出し元がトークンの aud に含まれない場合の `{active:false}`）は実装・テスト済み。

## 6. 改善・追加を検討する理由

本リポジトリは仕様参照の明記を必須としており（README）、規範からの逸脱は記録があって初めて Fidelity のシグナルとして機能する。実装するなら resource / scope マッピングというデータモデルの追加が要り、RFC 8707（resource indicators）の導入判断（`study-material/ext-resource-indicators-rfc8707.md`）と絡むため、単独では決められない。

## 7. 実装方針の候補（未確定。タスク化しない理由）

- 案 A: specification.md（または昇格レビューの検討事項）へ「scope-RS 対応表を持たないため絞り込みは行わない」という設計判断を追記する（記録のみ）。
- 案 B: RFC 8707 の resource パラメータ導入と併せて scope-RS マッピングを持ち、`restrictIntrospectionResponseToCaller` で絞り込む（実装）。
- 案 B は RFC 8707 側の方針決定に従属するため、ここでは決めない。案 A だけ先行する選択もある。

## 8. タスク案

- [ ] 案 A / B の方針決定（人間の判断待ち）。案 A のみ先行する場合は文書修正タスクとして切り出す
