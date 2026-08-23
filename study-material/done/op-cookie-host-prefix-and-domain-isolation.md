# OP セッション / トランザクション束縛 Cookie の `__Host-` プレフィックス欠落とサブドメイン隔離

## ステータス

🟠 High（セキュリティ・実装と設計文書の乖離）/ 未着手

## 1. このトピックで確認したいこと

生成 OP がブラウザへ発行する 2 種類の Cookie が、いずれも **名前プレフィックス（`__Host-`）を持たない**点を確認する。

- OP セッション Cookie: `session_id`
- トランザクション束縛 Cookie: `oidc_txn_<transactionId>`

属性としては `HttpOnly; Secure; SameSite=Lax; Path=/`（トランザクション側は `Max-Age` 付き）が付いており、
**属性面は既に妥当**である。欠けているのは「その属性が実際に付いていたことをブラウザに保証させる」名前プレフィックスと、
「同一サイトの別ホストがこの Cookie を書けない」というドメイン隔離の保証である。

加えて、この `__Host-` プレフィックスは **本リポジトリのタスク文書が一度は明示的に規定していた**ものであり、
実装時に落ちたまま完了扱いになっている（§4.3）。仕様上の理想論ではなく、**自リポジトリの設計意図との乖離**として扱う。

本ファイルで整理するのは以下。

- `__Host-` が無いことで具体的に何が可能になるか（サブドメインからの Cookie 書き込み → シャドーイング → セッション固定）
- 現在の実装で Cookie を読む側（`parseSessionId`）がシャドーイングにどう反応するか
- ローカル開発（`http://127.0.0.1:3010`）で `__Host-` が使えるかという実務上の制約
- 導入する場合の互換性影響（既存セッションの扱い、`conformance.test.ts` の期待値更新）

### 既存ファイルとの差分（重複回避）

| 論点 | 扱っているファイル |
|---|---|
| トランザクション束縛 Cookie の**仕組みそのもの**（束縛シークレット、ハッシュ保存、検証位置） | `study-material/done/auth-transaction-user-agent-binding.md`、`tasks/done/p1-auth-transaction-user-agent-binding.md` |
| OP セッションの**寿命・絶対有効期限・失効** | `study-material/done/op-session-lifecycle-and-expiry.md`、`tasks/p2-op-session-absolute-lifetime.md` |
| `Secure` / `HttpOnly` / `SameSite` を**含む HTTP セキュリティヘッダ全般**と TLS | `study-material/http-security-headers-and-tls.md` |
| CSRF トークンの定数時間比較 | `study-material/done/csrf-token-constant-time-comparison.md`、`tasks/p3-csrf-token-constant-time-comparison.md` |
| Node アダプタの `Set-Cookie` ヘッダ折り畳み | `study-material/done/generated-node-adapter-set-cookie-header-folding.md` |

本ファイルは上記のいずれとも異なり、「**Cookie の名前空間をホスト単位に隔離できているか**」という 1 点に絞る。
束縛の仕組み・寿命・属性値の妥当性は既存ファイルの結論をそのまま前提にする。

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 RFC 6265bis §4.1.3 — Cookie 名プレフィックス

`draft-ietf-httpbis-rfc6265bis`（RFC 6265 の後継、Cookie の現行仕様作業）は 2 つの名前プレフィックスを定義する。

- **`__Secure-`**: `Secure` 属性が付いていなければブラウザが Cookie を拒否する。
- **`__Host-`**: `Secure` が付き、`Domain` 属性が**無く**（＝ host-only）、`Path=/` である場合にのみ受理される。

`__Host-` の本質は「属性の強制」ではなく、**同一サイト内の別ホストがその名前の Cookie を書き込めなくなる**ことにある。
`Domain=example.com` を伴う Cookie は `__Host-` プレフィックスと両立しないため、
`sub.example.com` は `__Host-session_id` という名前の Cookie を `op.example.com` へ届けられない。

補足（正確性のため）: RFC 6265bis は本稿執筆時点で Internet-Draft の段階だが、
プレフィックスの挙動は主要ブラウザ（Chromium / Firefox / WebKit）で長期にわたり実装されている。
「仕様が Proposed Standard ではない」ことと「ブラウザが実装していない」ことは別である。

### 2.2 RFC 6265 §8.5 / §8.6 — Cookie は origin ではなくドメインで隔離される

RFC 6265 の Security Considerations は明示的に次を述べる。

- Cookie は **同一オリジンポリシーに従わない**。`https://op.example.com` と `http://other.example.com` は
  Cookie の観点では同じ「サイト」を共有しうる。
- したがって、あるホストが受け取る Cookie は **別のホスト（親ドメインを共有する兄弟ホスト、あるいは親ドメイン自身）が
  書き込んだ可能性**を常に持つ。`Secure` 属性はネットワーク上の盗聴を防ぐが、
  **非セキュアな兄弟ホストからの書き込みは防がない**（§8.6 "Weak Integrity"）。

これが `__Host-` を必要とする根拠であり、OP のように「Cookie の値がユーザーの同一性を決める」サーバでは重みが大きい。

### 2.3 攻撃の形（セッション固定 → 同一性の取り違え）

OP セッション Cookie に対する具体的な帰結:

1. 攻撃者が `evil.example.com`（同じ登録可能ドメイン配下の兄弟ホスト。XSS を得た正規サブドメイン、
   放置されたサブドメイン、あるいは DNS 委譲の残骸でもよい）から
   `Set-Cookie: session_id=<攻撃者が確立済みのセッション ID>; Domain=example.com; Path=/` を送る。
2. 被害者のブラウザは `op.example.com` へのリクエストにもこの Cookie を付ける。
3. OP は「このブラウザは攻撃者の subject としてログイン済み」と判定する。
4. 被害者が RP から来た認可リクエストで SSO 経路（`study-material/done/cli-generated-provider-browser-session-and-sso.md`）に乗ると、
   **攻撃者のアカウントとして認可コードが発行される**。被害者は自分のアカウントだと思ったまま、
   攻撃者のアカウントに RP 側のデータを書き込むことになる。

これは「攻撃者が被害者になりすます」方向ではなく「**被害者を攻撃者のアカウントに閉じ込める**」方向の攻撃であり、
RP 側に個人情報や決済情報を入力させる文脈で実害が出る。

トランザクション束縛 Cookie（`oidc_txn_<id>`）についても同様に、兄弟ホストからの上書きにより
**正規のブラウザ自身が束縛検証に失敗する（DoS）** ことが起こりうる。

### 2.4 OAuth 2.0 for Browser-Based Apps / RFC 9700 との関係

ブラウザベース BCP と RFC 9700 は、認可サーバのセッション Cookie に対して
`HttpOnly` / `Secure` / `SameSite` の付与を推奨しているが、**プレフィックスまで名指ししてはいない**。
したがって本トピックは「BCP 違反の修正」ではなく、**BCP の意図（Cookie の完全性）を実際に成立させるための実装手段**である。

## 3. 参照資料

- draft-ietf-httpbis-rfc6265bis §4.1.3 Cookie Name Prefixes — https://datatracker.ietf.org/doc/draft-ietf-httpbis-rfc6265bis/
- RFC 6265 HTTP State Management Mechanism §8.5 Weak Confidentiality / §8.6 Weak Integrity — https://www.rfc-editor.org/rfc/rfc6265#section-8.5
- RFC 6265 §5.4 The Cookie Header（複数の同名 Cookie が送られる際の順序規則） — https://www.rfc-editor.org/rfc/rfc6265#section-5.4
- RFC 9700 Best Current Practice for OAuth 2.0 Security — https://www.rfc-editor.org/rfc/rfc9700
- OAuth 2.0 for Browser-Based Applications（draft-ietf-oauth-browser-based-apps） — https://datatracker.ietf.org/doc/draft-ietf-oauth-browser-based-apps/
- 本リポジトリ内: `tasks/done/p1-auth-transaction-user-agent-binding.md:159`（`__Host-oidc_txn` を規定した箇所）

## 4. 現在の実装確認

### 4.1 Cookie 名と属性

`samples/hono-cloudflare/src/oidc-provider/store.ts`（生成元は `packages/cli/src/frameworks/*/templates.ts`）

```ts
export const SESSION_COOKIE_NAME = 'session_id';                              // :222

export function buildSessionCookie(sessionId: string): string {               // :269
  return SESSION_COOKIE_NAME + '=' + sessionId + '; HttpOnly; Secure; SameSite=Lax; Path=/';
}
```

トランザクション束縛 Cookie は `oidc_txn_<transactionId>` という名前で発行される
（`conformance.test.ts:924` が `'; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=600'` で終わることを固定している）。

いずれも `Domain` 属性を付けていないため **実際には host-only** で動く。
つまり現状の挙動自体は `__Host-` が要求する条件をすべて満たしている。
不足しているのは、**その条件が満たされていることをブラウザに検証させ、別ホストからの書き込みを拒否させる**プレフィックスだけである。

### 4.2 Cookie を読む側の挙動

```ts
export function parseSessionId(cookieHeader: string | null): string | undefined {  // :249
  if (!cookieHeader) return undefined;
  for (const part of cookieHeader.split(';')) {
    const trimmed = part.trim();
    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;
    if (trimmed.slice(0, eq) === SESSION_COOKIE_NAME) {
      return trimmed.slice(eq + 1);   // ← 最初に一致したものを返す
    }
  }
  return undefined;
}
```

同名 Cookie が 2 つ送られた場合（host-only の正規 Cookie と、`Domain` 付きの注入 Cookie）、
`Cookie` ヘッダ内の並び順は RFC 6265 §5.4 の規則（パスの長い順、同一なら生成時刻の早い順）に従う。
**どちらが先に来るかはブラウザの状態に依存**し、注入側が先に来る状況は成立しうる。
実装は最初の一致を返すため、その場合は注入された値が採用される。

（注: これは「必ず注入が勝つ」という主張ではない。**どちらが勝つかがサーバ側で決定できていない**ことが問題である。）

### 4.3 タスク文書との乖離

`tasks/done/p1-auth-transaction-user-agent-binding.md` は修正方針の中で次を規定していた。

```
// __Host-oidc_txn=<secret>; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=<transaction TTL>
```

同様に `study-material/done/auth-transaction-user-agent-binding.md:211` にも
`Set-Cookie: __Host-oidc_txn=<secret>; ...` と記載がある。
しかし実装された Cookie 名は `oidc_txn_<transactionId>`（プレフィックス無し）であり、
タスクは完了・`done` 移動済みである。**設計文書に書かれた要素が実装で落ちたまま完了した**状態。

セッション Cookie（`session_id`）については、そもそもプレフィックスを規定した文書が存在しない。

## 5. 現在の実装との差分

### 満たしていること

- `HttpOnly` / `Secure` / `SameSite=Lax` / `Path=/` はすべて付与済み。`SameSite` の値選択（`Strict` ではなく `Lax`）の
  根拠もコード内コメントに記述されている。
- `Domain` 属性を付けていないため、実際の送信範囲は既に host-only。
- トランザクション束縛の仕組み自体（束縛シークレットのハッシュ保存、定数時間比較）は導入済み。

### 不足している可能性があること

- **兄弟ホストからの Cookie 書き込みを拒否する手段が無い**。属性の正しさは「OP が正しく送っている」ことしか保証せず、
  「他人が同じ名前で書いていない」ことは保証しない（RFC 6265 §8.6）。
- **同名 Cookie が複数届いたときの選択が未定義**。`parseSessionId` は最初の一致を返すだけで、
  重複検知も、複数一致時の拒否も行わない。
- **設計文書と実装の乖離が検知されていない**。`conformance.test.ts` は現在の名前（プレフィックス無し）を固定しているため、
  乖離はテストによって「正」として固定されている。

### セキュリティ上、改善した方がよいこと

- OP を独自ドメインのサブドメイン（`auth.example.com` 等）で運用する構成は一般的であり、
  その構成では兄弟ホストが必ず存在する。OSS の既定として `__Host-` を付けておく価値が高い。

### 相互運用性 / 開発体験の観点で確認すべきこと

- **`__Host-` は `Secure` を必須とする**。サンプルの既定 issuer は `http://127.0.0.1:3010` である。
  主要ブラウザは `localhost` / `127.0.0.1` を potentially trustworthy origin として扱い、
  http でも `Secure` Cookie の設定を許容する実装になっているが、
  **本リポジトリの E2E（Playwright）で実際に動くかは検証が必要**であり、推測で断定すべきではない。
  ここは「要検証」として明記する。
- `conformance.test.ts` は Cookie 文字列を `endsWith` / 完全一致で固定しているため、名前を変えると複数箇所の期待値更新が必要。

### Basic OP として提供する上で確認すべきこと

- Basic OP 認定は OP の Cookie 名を検査しない。**認定ブロッカーではない**。
- ただし認定テストはブラウザ経由で SSO / `prompt=none` / `max_age` を叩くため、
  Cookie が設定されない環境（`__Host-` を http で拒否するブラウザ）では認定実行が失敗する。導入時は必ず E2E で確認すること。

## 6. 改善・追加を検討する理由

- **既に自分たちで決めていた**: `__Host-` はこのリポジトリのタスク文書が明示的に要求していた要素であり、
  新規の提案ではなく「積み残しの回収」である。判断コストが低い。
- **修正が局所的**: Cookie 名の定数と、`Set-Cookie` を組み立てる 3 関数、それを読む 2 関数、
  そして期待値を固定している `conformance.test.ts`（生成元は `packages/cli`）に閉じる。core への変更は不要。
- **OSS 利用者の事故を減らす**: 利用者は生成コードをカスタマイズしてよい方針だが、
  「Cookie 名にプレフィックスを付けるべき」という知識を全員が持っている前提には立てない。既定で安全側に倒す価値がある。
- **`SameSite=Lax` の限界を補う**: `SameSite` はクロスサイトの**送信**を制限するが、
  同一サイト内の兄弟ホストからの**書き込み**は制限しない。両者は別の防御であり、片方だけでは穴が残る。
- **実装しない場合に残るリスク**: サブドメイン運用時のセッション固定経路が開いたままになり、
  「セキュリティ最優先」という方針と実装が食い違う。設計文書との乖離も検知されないまま残る。

## 7. 実装方針の候補

### 方針 A：両 Cookie に `__Host-` を付ける（本番既定）＋ ローカル開発のフォールバックを設けない

`session_id` → `__Host-session_id`、`oidc_txn_<id>` → `__Host-oidc_txn_<id>` に変更する。

- 利点: 最も単純で、条件分岐が生まれない。挙動が環境で変わらない。
- 欠点: `http://127.0.0.1` のローカル起動（`pnpm sample:*`）で Cookie が拒否されるとサンプルが起動しても認証できない。
  ブラウザの localhost 例外に依存することになるため、**E2E での実測が前提条件**。

### 方針 B：issuer の scheme で名前を切り替える

`config.issuer` が `https:` のときだけ `__Host-` を付け、`http:`（ローカル開発）では従来名を使う。

- 利点: ローカル開発が確実に壊れない。本番デプロイでは自動的に強い名前になる。
- 欠点: 環境で Cookie 名が変わるため、生成コードを読む利用者にとって挙動が 1 段複雑になる。
  http で本番運用してしまった利用者は保護されない（ただしその構成は元々 `Secure` Cookie が機能しない）。

### 方針 C：名前は変えず、読み側で同名重複を検知して拒否する

`parseSessionId` を「一致した Cookie を全部集め、2 件以上あればセッション無しとして扱う」実装に変える。

- 利点: Cookie 名の互換性を壊さない。`conformance.test.ts` の期待値更新が最小。
- 欠点: 攻撃者が正規 Cookie の存在しないタイミング（未ログイン状態）で 1 件だけ注入した場合は検知できない。
  根本解決にならず、`__Host-` の代替にはならない。

### 方針 D：方針 B ＋ 方針 C の併用

名前で書き込みを防ぎ、読み側でも重複を検知する。

- 利点: 多層防御。`__Host-` が効かない環境（古いブラウザ、http 運用）でも劣化した防御が残る。
- 欠点: 変更点が最も多い。

**判断材料**: ローカル開発の既定が `http://127.0.0.1` である以上、方針 A を採るには
「主要ブラウザが localhost で `__Host-` Cookie を受理する」ことの実測が必須。
実測できるなら A が最も単純。実測が取れない、または CI 環境のブラウザ差を許容したくないなら B。
最終判断は人間が行う。

## 8. タスク案

- [ ] Playwright E2E で `http://127.0.0.1:<port>` に対して `__Host-` 付き Cookie が受理されるかを実測し、結果を記録する（方針 A / B の分岐条件）
- [ ] 実測結果に基づき方針（A / B / C / D）を決定する
- [ ] `packages/cli` のテンプレートで Cookie 名定数と `Set-Cookie` 組み立て（セッション用・トランザクション用・クリア用）を更新する
- [ ] Cookie 読み取り側（`parseSessionId` / トランザクション Cookie パーサ）を新しい名前に追随させる
- [ ] 同名 Cookie が複数届いた場合の挙動を決め、実装とテストで固定する（方針 C / D を採る場合）
- [ ] `samples/*/conformance.test.ts` の生成元を更新し、Cookie 名と属性を新しい期待値で固定する
- [ ] `study-material/done/auth-transaction-user-agent-binding.md` と `tasks/done/p1-auth-transaction-user-agent-binding.md` の
      記述（`__Host-oidc_txn`）と実装が一致した状態にする、または乖離の理由を追記する
- [ ] 既存セッションの互換性（Cookie 名変更により既存ログインが一度切れる）を許容するかを判断し、必要なら移行の注意点を記載する
