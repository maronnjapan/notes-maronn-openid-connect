# [P3] EdDSA（Ed25519）署名の Web Crypto 可用性を検証する（Portability ゲート）

## ステータス

✅ 完了（2026-07-21、調査タスク）

## 背景

EdDSA（Ed25519, RFC 8037 / RFC 8032）は鍵・署名が小さく高速で、モバイル / IoT / モダン RP での採用が増えている。本リポジトリの per-client 署名 alg 選択機構（`selectSigningKeyByAlg`）に乗せれば ID Token / UserInfo JWT で `alg=EdDSA` を選べるようになる。

ただし Web Crypto API への `Ed25519` 追加は比較的新しく、ランタイム間でサポート状況に差がある。本リポジトリの差別化軸 **Portability（JS が動けばどこでも動く）** と衝突しうるため、実装の前に対象ランタイムでの可用性を確定する必要がある。本タスクはその**調査ゲート**であり、実装は調査結果次第とする。

検討の経緯は `study-material/done/signing-alg-eddsa-ps256-interop.md`（方針 B）を参照。

## 対象ファイル

- 調査結果の追記先: `study-material/done/signing-alg-eddsa-ps256-interop.md`（§3.5 / §9 の EdDSA 項目）
- 実装する場合の対象（参考）: `packages/core/src/crypto-utils.ts` / `jwks.ts`（`kty=OKP` / `crv=Ed25519` 入出力、`EdDSA` 署名・検証・alg 派生）

## 仕様参照

- RFC 8037 — CFRG Curves in JOSE（`EdDSA` alg / `kty=OKP` / `crv=Ed25519`）。
- RFC 8032 — EdDSA（Ed25519 署名）。
- W3C Secure Curves in the Web Cryptography API（`Ed25519` アルゴリズム）。
- OIDC Core 1.0 §15.1 — RS256 必須、EdDSA は任意（RS256/ES256 フォールバックは必ず残す）。

## 調査項目（チェックリスト）

- [x] 以下の各ランタイムで Web Crypto の `crypto.subtle.generateKey({ name: 'Ed25519' }, ...)` / `sign` / `verify` / `importKey`・`exportKey`（OKP JWK 入出力）が動作するか検証する:
  - [x] Node.js（Node 20.19.3 から stable。Node 24.18.0 で実測）
  - [x] Cloudflare Workers（公式対応表で確認）
  - [x] Deno（Deno 1.26 公式リリース情報で確認。ローカル実測環境なし）
  - [x] 主要ブラウザ（Chromium 148 で実測、Firefox 129 / Safari 17・18.4・26 は公式情報で確認）
- [x] OKP JWK の入出力フォーマット（`{ "kty":"OKP", "crv":"Ed25519", "x":"..." }`）を Node と Chromium 間で相互検証した。
- [x] EdDSA を当面「opt-in / 環境依存機能」とし、RS256/ES256 フォールバックで Portability を担保する推奨方針を整理した。
- [x] 調査結果（対応ランタイム一覧・制約・推奨方針）を `study-material/done/signing-alg-eddsa-ps256-interop.md` §3.5 / §9 に追記した。

## 完了条件

- 上記ランタイムでの `Ed25519` 可用性が一覧として `study-material/done/signing-alg-eddsa-ps256-interop.md` に記録され、EdDSA を実装するか（するなら opt-in 化が必要か）の判断材料が揃っていること。
- 実装可否の最終判断は人間が行う（本タスクは調査までを完了範囲とする）。
