# [P3] Basic OP certification plan の module 一覧を確定し、テスト層との対応を記録する

## ステータス

🟢 Low / 未着手

## 背景

本リポジトリは Basic OP 認定を Fidelity の signal として掲げているが、
**「Basic OP として満たすべき module の全集合」がリポジトリ内で確定していない。**

- 実行しているプランは
  `oidcc-basic-certification-test-plan[server_metadata=discovery][client_registration=static_client]`
  で、2026-06-21 の実測記録（`tasks/done/p1-basic-op-static-client-conformance-result-2026-06-21.md`）は
  **35 module** と記録している。
- 一方、OIDF Conformance Suite の `OIDCCBasicTestPlan.java` から確認できた module 一覧は **38 件**だった。
- certification plan は variant による絞り込みを伴うため差分が出ると考えられるが、
  **certification plan 側のソースは調査時に取得できず、対応関係が未確定**である。

この状態だと次の判断ができない。

- 新機能を足したとき、どの module に影響するのか
- どの module が契約テスト（`samples/*/conformance.test.ts`）で先取り済みで、
  どれが Suite / E2E / manual review 専任なのか
- Suite のバージョンが上がって module が増えたとき、何が増えたのか

また、Suite は仕様条文に書かれていない判定も行う。例えば `CompareIdTokenClaims` は
「初回 ID Token に `azp` が無ければ再発行にも `azp` があってはならない」「`iat` が同値ならエラー」を
実装しており、`RefreshTokenRequestSteps` はアクセストークンの**一意性**・最小エントロピー・許可文字種を検査する。
**認定の合否は Suite の判定ロジックで決まる**ため、仕様条文だけを根拠にテストを書くとこれらを取りこぼす。

検討詳細は `study-material/done/conformance-suite-cross-request-invariants-in-contract-tests.md` を参照。

> 関連: Suite の実行手順は `tests/conformance/README.md` と
> `study-material/basic-op-conformance-verification-plan.md`。仕様要件のトレーサビリティは
> `study-material/basic-op-requirement-traceability.md`。
> クロスリクエスト不変条件を契約テストへ追加する作業自体は
> `tasks/p1-token-value-uniqueness-and-refresh-idtoken-iat.md` のテスト要件に含まれる。
> 本タスクは**一覧の確定と記録**に限定する。

## 対象ファイル

- `tests/conformance/README.md`（module 一覧と対応表の置き場所の第一候補）
- `study-material/basic-op-requirement-traceability.md`（列を足す方針を採る場合）

## 仕様参照

- **OpenID Connect Conformance Profiles / OP テスト手引き**（OpenID Foundation）—
  https://openid.net/certification/connect_op_testing/
  認定には「プロファイル内の全 module が PASSED / REVIEW / WARNING / SKIPPED」であることが必要で、
  FAILED / INTERRUPTED が 1 つでもあると認定できない。
- **OIDF Conformance Suite `OIDCCBasicTestPlan`** —
  https://gitlab.com/openid/conformance-suite/-/raw/master/src/main/java/net/openid/conformance/openid/OIDCCBasicTestPlan.java
- **OIDF Conformance Suite `OIDCCRefreshToken`** —
  https://gitlab.com/openid/conformance-suite/-/raw/master/src/main/java/net/openid/conformance/openid/OIDCCRefreshToken.java
- **OIDF Conformance Suite `RefreshTokenRequestSteps`** —
  https://gitlab.com/openid/conformance-suite/-/raw/master/src/main/java/net/openid/conformance/sequence/client/RefreshTokenRequestSteps.java
- **OIDF Conformance Suite `CompareIdTokenClaims`** —
  https://gitlab.com/openid/conformance-suite/-/raw/master/src/main/java/net/openid/conformance/condition/client/CompareIdTokenClaims.java

## 現状の実装

- `tests/conformance/README.md` は実行手順・実測結果・manual review 手順を詳細に記録しているが、
  **module の全一覧は持っていない**（個別 module 名が本文中に散在するのみ）。
- `study-material/basic-op-requirement-traceability.md` は仕様要件のトレーサビリティを扱うが、
  **Suite の module 名は 1 件も含まれていない**。
- `samples/*/src/oidc-provider/conformance.test.ts` は 112 の `it` を持つが、
  どの Suite module に対応するかの注記は一部にとどまる。

## 修正方針

- [ ] `oidcc-basic-certification-test-plan[server_metadata=discovery][client_registration=static_client]`
      の module 一覧を確定する。次のいずれかで取得する:
  - [ ] Suite の certification plan クラス（`OIDCCBasicCertification*`）のソースを取得する
  - [ ] `pnpm run conformance:basic-op` の実行結果 zip（`tests/conformance/results/*.zip`）から
        module 名を機械的に抽出する（実行環境がある場合はこちらが確実）
- [ ] `OIDCCBasicTestPlan` の 38 件との差分（3 件）が何で、なぜ certification plan から外れるのかを記録する
- [ ] 確定した一覧を `tests/conformance/README.md` に表として置く。各行に次を持たせる:
  - module 名
  - 直近の実行結果（PASSED / SKIPPED / WARNING / manual review 待ち）
  - 対応するテスト層（契約テストで先取り済み / `tests/e2e` 担当 / Suite 専任＝manual review）
- [ ] Suite ソースを一次情報として参照する運用を採るかを判断し、採る場合は
      **参照した Suite のバージョン（またはコミット）を文書に明記する**運用を決める
      （Suite の判定ロジックはバージョンで変わりうるため、無記名の引用は陳腐化する）

## テスト要件

本タスクは文書化タスクのため自動テストは伴わない。代わりに次を完了確認の材料とする。

- [ ] 確定した module 一覧の件数が、直近の実行結果の module 数と一致すること
- [ ] 一覧の各 module について、テスト層の割り当てが空欄なく埋まっていること
- [ ] 「契約テストで先取り済み」と分類した module について、
      `samples/*/src/oidc-provider/conformance.test.ts` に該当する `describe` / `it` が実在すること

## 完了条件

- `tests/conformance/README.md` に Basic OP certification plan の module 全一覧と
  テスト層の対応表が入っている
- 38 件 vs 35 件の差分が解消され、理由が記録されている
- Suite ソースを参照する運用の可否が判断され、採る場合は参照バージョンの明記ルールが決まっている
