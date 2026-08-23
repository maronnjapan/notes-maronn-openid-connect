# [P2] OP セッション / トランザクション束縛 Cookie に `__Host-` プレフィックスを導入する

## ステータス

🟡 Medium / 未着手（着手前に §テスト要件の実測ステップが必要）

## 背景

生成 OP がブラウザへ発行する 2 種類の Cookie が、いずれも名前プレフィックスを持たない。

- OP セッション Cookie: `session_id`
- トランザクション束縛 Cookie: `oidc_txn_<transactionId>`

属性は `HttpOnly; Secure; SameSite=Lax; Path=/`（トランザクション側は `Max-Age` 付き）で、
`Domain` 属性を付けていないため**実際には host-only で動いている**。
不足しているのは、その条件が満たされていることをブラウザに検証させ、
**別ホストからの書き込みを拒否させる** `__Host-` プレフィックスだけである。

RFC 6265 §8.6（Weak Integrity）が明記するとおり、Cookie は同一オリジンポリシーに従わない。
`Secure` 属性はネットワーク上の盗聴を防ぐが、**同じ登録可能ドメインを共有する兄弟ホストからの書き込みは防がない**。
OP を `auth.example.com` のようなサブドメインで運用する構成は一般的であり、その場合:

1. 攻撃者が兄弟ホスト（XSS を得た正規サブドメイン、放置されたサブドメイン等）から
   `Set-Cookie: session_id=<攻撃者のセッション ID>; Domain=example.com; Path=/` を送る
2. 被害者のブラウザは `auth.example.com` へのリクエストにもこの Cookie を付ける
3. OP は「このブラウザは攻撃者の subject としてログイン済み」と判定する
4. 被害者が RP から来た認可リクエストで SSO 経路に乗ると、**攻撃者のアカウントとして認可コードが発行される**

被害者は自分のアカウントだと思ったまま攻撃者のアカウントを使い続けることになり、
RP 側に個人情報や決済情報を入力させる文脈で実害が出る（セッション固定 → 同一性の取り違え）。

さらに、この `__Host-` は**本リポジトリのタスク文書が一度は明示的に規定していた**要素である。
`tasks/done/p1-auth-transaction-user-agent-binding.md:159` と
`study-material/done/auth-transaction-user-agent-binding.md:211` はいずれも
`__Host-oidc_txn=<secret>; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=<TTL>` と記載しているが、
実装された Cookie 名は `oidc_txn_<transactionId>`（プレフィックス無し）で、
タスクは完了・`done` 移動済みである。**設計文書に書かれた要素が実装で落ちたまま完了した**状態を回収する。

検討詳細は `study-material/done/op-cookie-host-prefix-and-domain-isolation.md` を参照。

> 関連（重複しない）: 束縛の仕組みそのもの（束縛シークレット・ハッシュ保存・検証位置）は
> `tasks/done/p1-auth-transaction-user-agent-binding.md`、
> セッション寿命は `tasks/p2-op-session-absolute-lifetime.md` が扱う。
> 本タスクは **Cookie の名前空間をホスト単位に隔離する**ことだけを対象とする。

## 対象ファイル

- `packages/cli/src/frameworks/*/templates.ts`
  - Cookie 名定数（`SESSION_COOKIE_NAME`、トランザクション Cookie 名の組み立て）
  - `Set-Cookie` 組み立て（`buildSessionCookie` / `buildTransactionBindingCookie` / クリア用）
  - Cookie 読み取り（`parseSessionId` / トランザクション Cookie パーサ）
- 各 sample の `conformance.test.ts` を生成する `packages/cli` 側コード
  （Cookie 文字列を `endsWith` / 完全一致で固定しているため期待値更新が必要）
- `tests/e2e`（実測ステップと回帰確認）
- 生成物（直接編集しない・確認用）: `samples/hono-cloudflare/src/oidc-provider/store.ts:222, 249-260, 269-270, 1002, 1013`

## 仕様参照

- **draft-ietf-httpbis-rfc6265bis §4.1.3 Cookie Name Prefixes**:
  `__Host-` プレフィックスが付いた Cookie は、`Secure` が付き、`Domain` 属性が無く（host-only）、
  `Path=/` である場合にのみブラウザが受理する。
  本質は属性の強制ではなく、**同一サイト内の別ホストがその名前の Cookie を書き込めなくなる**こと。
  （注: RFC 6265bis は Internet-Draft だが、プレフィックスの挙動は Chromium / Firefox / WebKit で長期に実装済み）
- **RFC 6265 §8.5 Weak Confidentiality / §8.6 Weak Integrity**:
  Cookie は同一オリジンポリシーに従わない。`Secure` 属性は非セキュアな兄弟ホストからの**書き込み**を防がない。
- **RFC 6265 §5.4 The Cookie Header**:
  同名 Cookie が複数ある場合の送信順はパス長・生成時刻で決まる。
  サーバが「どちらが正規か」を決定できないため、読み取り側の重複検知も検討対象になる。
- **RFC 9700 / OAuth 2.0 for Browser-Based Apps**:
  AS のセッション Cookie に `HttpOnly` / `Secure` / `SameSite` を推奨するが、プレフィックスは名指ししていない。
  本タスクは BCP 違反の修正ではなく、**BCP の意図（Cookie の完全性）を実際に成立させるための実装手段**。

## 現状の実装

```ts
// samples/hono-cloudflare/src/oidc-provider/store.ts:222
export const SESSION_COOKIE_NAME = 'session_id';

// :269-270
export function buildSessionCookie(sessionId: string): string {
  return SESSION_COOKIE_NAME + '=' + sessionId + '; HttpOnly; Secure; SameSite=Lax; Path=/';
}

// :249-260  同名 Cookie が複数届いた場合、最初の一致を返す
export function parseSessionId(cookieHeader: string | null): string | undefined {
  if (!cookieHeader) return undefined;
  for (const part of cookieHeader.split(';')) {
    const trimmed = part.trim();
    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;
    if (trimmed.slice(0, eq) === SESSION_COOKIE_NAME) {
      return trimmed.slice(eq + 1);   // ← 重複検知なし
    }
  }
  return undefined;
}
```

トランザクション束縛 Cookie も同様に `oidc_txn_<transactionId>` という名前で、
`conformance.test.ts:924` が `'; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=600'` で終わることを固定している。

## 修正方針

`__Host-` は `Secure` を必須とする。サンプルの既定 issuer は `http://127.0.0.1:3010` である。
主要ブラウザは `localhost` / `127.0.0.1` を potentially trustworthy origin として扱い
http でも `Secure` Cookie の設定を許容する実装になっているが、
**本リポジトリの E2E（Playwright）で実際に動くかは推測せず実測すること**。
実測結果によって方針 A / B が分岐する。

- [ ] **（先行）** Playwright E2E で `http://127.0.0.1:<port>` に対し `__Host-` 付き Cookie が受理されるかを実測し、結果を記録する
- [ ] 実測結果に基づき方針を決定する
  - 方針 A（受理される場合）: 環境によらず常に `__Host-` を付ける
  - 方針 B（受理されない場合）: `config.issuer` の scheme が `https:` のときだけ `__Host-` を付ける
- [ ] Cookie 名定数と `Set-Cookie` 組み立て（セッション用・トランザクション用・クリア用）を更新する
- [ ] Cookie 読み取り側（`parseSessionId` / トランザクション Cookie パーサ）を新しい名前に追随させる
- [ ] 読み取り側で**同名 Cookie の重複を検知**し、2 件以上ある場合はセッション無しとして扱う（多層防御）
- [ ] `study-material/done/auth-transaction-user-agent-binding.md` と
      `tasks/done/p1-auth-transaction-user-agent-binding.md` の記述と実装が一致した状態にする
- [ ] Cookie 名変更により既存ログインが一度切れることを許容するか判断し、必要なら README に移行の注意点を記載する
- [ ] 生成コードは直接編集せず `packages/cli` テンプレートを修正する

実装例（方針 B）:

```ts
/**
 * OP セッション Cookie の名前。
 *
 * RFC 6265bis §4.1.3.2: `__Host-` プレフィックスが付いた Cookie は、Secure 属性があり
 * Domain 属性が無く Path=/ の場合のみブラウザが受理する。これにより、同じ登録可能
 * ドメインを共有する兄弟ホスト（例: XSS を得たサブドメイン）がこの名前の Cookie を
 * 書き込めなくなる。RFC 6265 §8.6 が述べるとおり Secure 属性だけでは非セキュアな
 * 兄弟ホストからの書き込みを防げず、OP セッション Cookie の固定は
 * 「被害者を攻撃者のアカウントに閉じ込める」攻撃に直結するため、名前側でも隔離する。
 *
 * `__Host-` は Secure を必須とするため、http のローカル開発ではプレフィックスを外す。
 */
export function sessionCookieName(issuer: string): string {
  return new URL(issuer).protocol === 'https:' ? '__Host-session_id' : 'session_id';
}
```

## テスト要件

- [ ] **（先行実測）** `tests/e2e` に、ローカル http origin で `__Host-` Cookie が受理されるかを確認する調査テストを追加し、
      結果をタスクまたは study-material に記録する
- [ ] `should set the session cookie with the __Host- prefix over https`
      — `issuer` が https の OP で `POST /login` 成功時の `Set-Cookie` が
      `__Host-session_id=<id>; HttpOnly; Secure; SameSite=Lax; Path=/` と完全一致すること
- [ ] `should set the transaction binding cookie with the __Host- prefix over https`
      — `GET /authorize` の `Set-Cookie` が
      `__Host-oidc_txn_<id>=<secret>; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=600` と完全一致すること
- [ ] `should clear the transaction binding cookie with the same prefixed name`
      — クリア用 `Set-Cookie` の名前が設定時と一致し、`Max-Age=0` であること
- [ ] `should never emit a Domain attribute on OP cookies`
      — すべての `Set-Cookie` に `Domain=` が含まれないこと（`__Host-` の前提条件）
- [ ] `should ignore the session cookie when the same name appears more than once`
      — `Cookie: __Host-session_id=a; __Host-session_id=b` を送ったとき、セッション無しとして扱われること
- [ ]（方針 B を採る場合）`should fall back to the unprefixed cookie name over http`
      — `issuer` が http の OP で Cookie 名が `session_id` になること
- [ ] `samples/*/conformance.test.ts` の Cookie 期待値（`endsWith` / 完全一致）をすべて更新する
- [ ] `tests/e2e` の既存 Playwright フロー（ログイン → 同意 → コールバック、SSO、`prompt=none`、`max_age`）が
      4 サンプルすべてで回帰しないこと

## 完了条件

- `pnpm --filter @maronn-openid-connect/cli test` がパスすること
- `pnpm test:conformance` がパスすること
- `pnpm test:e2e` がパスすること（Cookie が設定されない環境では認可フローが完全に壊れるため、E2E の通過が必須条件）
- `pnpm typecheck` がパスすること
- `study-material/done/auth-transaction-user-agent-binding.md` / `tasks/done/p1-auth-transaction-user-agent-binding.md` の
  記述と実装が一致していること、または乖離の理由が追記されていること
