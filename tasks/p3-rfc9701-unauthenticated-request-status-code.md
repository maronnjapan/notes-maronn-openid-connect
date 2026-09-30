# [P3] RFC 9701 有効時の未認証 introspection 応答コード（400 MUST と 401 慣行）の判断を確定する

## ステータス

🟢 Low / 未着手

## 背景

RFC 9701 §5 の Note は「本仕様に適合する AS は、呼び出し元を認証しない introspection リクエストを拒否し、HTTP ステータスコード 400 を返さなければならない（MUST）」と定める。
一方、生成 OP の introspection ルートは未認証・認証失敗を `invalid_client`（401 + `WWW-Authenticate`）で拒否する。
これは RFC 6749 §5.2 / RFC 7662 の慣行であり、`tasks/done/p1-introspection-reject-public-client-caller.md`（PR #95）で追加した public client 拒否も同じ 401 を返し、生成 conformance テストが 401 を固定している。

つまり「未認証は拒否する」という §5 の本体要求は満たしたが、ステータスコードは Note の字義（400）から逸脱しており、その判断がどこにも記録されていない。
`--enable jwt-introspection-response` を名乗る OP としては、逸脱の明文化か 400 への変更のどちらかが要る。
2026-09-30 の実装レビュー（Phase 2 ルーティーン）で検出した。

## 対象ファイル

判断の結果により異なる。

- 逸脱を明文化する場合: `tasks/experimental/done/jwt-introspection-response/specification.md` の準拠記述、`docs/library-document` の該当ページ、実装解説 `implementation-guides/experimental/jwt-introspection-response.{ja,en}.md`
- 400 へ変更する場合: 上記に加えて core の `IntrospectionError`（`invalid_client` の statusCode）または生成ルートのエラーマッピング、生成 conformance テスト（401 を固定している箇所）、4 サンプル再生成

## 仕様参照

- RFC 9701 §5 Note（未認証リクエストの拒否と 400 の MUST）
- RFC 6749 §5.2 / RFC 7662 §2.1（invalid_client は 401 + WWW-Authenticate が慣行）
- RFC 9110 §15.5.2（401 は認証チャレンジを伴う）

## 検討の観点

- 400 に変えると RFC 7662 のみ有効な OP（JSON 経路）との一貫性が崩れる。RFC 9701 有効時だけ 400 に切り替えると、機能フラグで共有ルートの認証エラー形が変わる（「明示された場合のみ挙動を変える」隔離原則との整合を確認する）
- 401 + WWW-Authenticate は「資格情報を付けて再試行せよ」という HTTP 意味論として正しく、Conformance Suite / 主要実装の挙動も確認材料になる
- どちらを選んでも、判断と根拠を仕様書と実装解説へ記録し、conformance テストの期待値と一致させることが完了条件

## 修正方針

- [ ] 一次資料（RFC 9701 §5 Note の位置づけ、他実装の挙動）を確認して 400 / 401 のどちらかに決める
- [ ] 決定を specification.md / Docs / 実装解説へ反映する
- [ ] 400 を選んだ場合のみ、実装とテストを更新する

## 完了条件

- 未認証時のステータスコードの決定と根拠が文書化され、実装・conformance テスト・Docs の三者が一致している
