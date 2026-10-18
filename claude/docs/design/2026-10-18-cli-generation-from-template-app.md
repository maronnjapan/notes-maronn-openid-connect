# CLI 生成コードを動くアプリから抽出する設計

- 日付: 2026-10-18
- 依頼: CLI が文字列で組み立てている生成コードを、第三者が修正しやすい形に変える。動くアプリを正とし、CLI はそこから OP のパッケージ部分を抽出する。既存の構成との互換性は考えない。
- 前提: Next.js はフレームワークの作法を崩さない。生成物の可読性を落とさない。

## 目的

この設計の目的は、`packages/cli` の生成コードを第三者がプルリクエストで直せる状態にすることである。
現在の CLI は生成コードを TypeScript の文字列として持っており、修正する側は文字列の中のコードを読み、生成結果を頭の中で展開しながら直すことになる。
文字列の中では型検査も補完も効かず、単体テストも書けないため、修正の正しさは生成してみるまで分からない。

達成したい状態は次の三つである。

- 生成コードのバグ修正が、実コードの差分一つと隣の単体テストで完結する
- 新しい機能の追加が、機能ごとのディレクトリの追加と登録一行で完結する
- 機能の組合せの正しさを、人手の生成ではなく CI の型検査で確かめられる

一方で、動くアプリを正にすると、機能の組合せごとにアプリが要るのではないか、そのアプリごとに E2E が要るのではないか、という懸念がある。
本設計はこの懸念に、アプリをフレームワークごとに一つに固定し、組合せは型検査だけで確かめる、という形で答える。

## 現状の確認

設計の前提として、現在のリポジトリを確認した結果を挙げる。

| 項目 | 値 |
|---|---|
| CLI のソース行数 | 約 24,500 行 |
| テンプレート内の `features.*` による分岐 | 495 箇所 |
| 直近 6 か月にテンプレートを変えたコミット | 41 件 |
| うち samples の生成物も同時に更新したコミット | 31 件 |
| 生成物が型検査される組合せ | samples の 4 つのみ（全機能オン + `--db`） |

テンプレートを変える作業の大半は、既に samples の再生成を伴っている。
つまり「アプリと一緒に直す」運用は今も行われており、変わるのは正の向きだけである。
一方で、機能をオフにした生成物や `--flow` で並べ替えた生成物は型検査されておらず、CLI の単体テストは文字列の有無を見るにとどまる。
CONTRIBUTING はなく、README は「生成物を直したいなら packages/cli を直す」とだけ述べている。

## 設計の原則

原則は四つある。

- **実コードを正にする**：CLI が出力するコードはすべて、リポジトリ内でコンパイルされ、テストされ、起動できる TypeScript として存在する。文字列リテラルの中にコードを置かない。
- **分岐ではなく合成で機能を表す**：一つの機能は一つのディレクトリであり、base 側のコードに `if (features.par)` のような分岐を書かない。機能のオンオフは、ディレクトリを含めるかどうかと、有効な機能を列挙する一ファイルの行数だけで決まる。
- **フレームワークごとに全機能オンのアプリを一つ持つ**：機能の組合せごとにアプリは作らない。このアプリは E2E の相手であり、貢献者が `pnpm dev` で起動する開発環境でもある。
- **組合せは型検査で確かめる**：E2E は全機能オンのアプリに対してだけ回す。機能を減らした生成物は、代表的な組合せを生成して `tsc --noEmit` を通すことで確かめる。

三つ目の原則について補足する。
Next.js は App Router の作法のままに書き、hono と共通化しない。
検討の途中で「ロジックを一本にして薄いアダプタで各フレームワークへ出す」案も出たが、Next.js の生成物が汎用化で読みにくくなるため採らない。
Next.js の token 周りは hono 側と関数名が三つしか共通しておらず、現状でも実質的に別のコードである。

## ディレクトリ構成

```
apps/                              生成元。独立した workspace パッケージで、それぞれ単体で起動できる
  hono/
    package.json                   hono、@hono/node-server、vitest
    src/server.ts                  dev 用の入口。メモリ DB と開発用のクライアントとユーザーを登録して待ち受ける
    src/oidc-provider/             CLI が抽出する範囲
      app.ts  config.ts  store.ts  resolvers.ts  views.tsx
      endpoints/token/pipeline.ts        ハンドラ本体。// [step-id] 付きの呼び出し列
      endpoints/token/steps/*.ts         1 ステップ 1 ファイル。隣に単体テスト
      features/enabled.ts                生成時に描画される
      features/pkce/  introspection/  revocation/  refresh-token/  request-object/   stable。既定でオン
      features/par/  token-exchange/  jarm/  ciba/ ...                               experimental
      features/google-login/                                                         extension
      db/index.ts                        生成時に描画される
      db/memory/  db/sql/  db/kv/
  nextjs/
    package.json                   next、react
    src/app/layout.tsx             アプリ側の土台。抽出しない
    src/dev-data.ts                開発用のクライアントとユーザー。抽出しない
    src/app/                       CLI が抽出する範囲。App Router の作法のまま
      _oidc-provider/features.ts         生成時に描画される
      _oidc-provider/features/<id>/      ルートを持たない機能ロジック
      authorize/route.ts  token/route.ts  login/page.tsx  consent/page.tsx    base
      (par)/par/route.ts                                                      route group が機能の所有を表す
      (device-authorization-grant)/device_authorization/route.ts
      (google-login)/login/google/route.ts
packages/cli/
  src/
    registry.ts            機能の一覧。id、tier、requires、必要パッケージ、対応フレームワーク
    generate.ts            ファイル選択とデータファイルの描画
    flow/                  graph と --flow。apps の meta から焼いた catalog.json を読む
  extract.json             どの app のどのパスを抽出し、何を除外するか
  templates/               gitignore。build 時に apps/*/ の抽出範囲を集めたコピー。npm には同梱する
samples/*                  今まで通り CLI の生成物。デプロイ先ごとの検証に使う
```

生成元のアプリを CLI パッケージの中に置かないのは、起動と依存関係のためである。
Next.js プロジェクトや dev サーバを CLI の中に抱えると、CLI の package.json がアプリの依存を持ち、起動手順も不自然になる。
`apps/` に独立した workspace パッケージとして置けば、`pnpm --filter app-hono dev` で全機能オンの OP が Node 上で立ち、抽出範囲のファイルを直せば watch で即反映される。
Next.js は `next dev` そのものである。
CLI は build 時に `extract.json` に従って抽出範囲を `templates/` へ集め、npm パッケージにはそのコピーを同梱する。

抽出の境界は `extract.json` に書く。
hono は `src/oidc-provider/**` をそのまま抽出し、Next.js は `src/app/**` からアプリ側の土台（`layout.tsx` など）を除外する。
CI は、抽出範囲の全ファイルが base か 1 機能か 1 db 種に属するか、除外に挙がっているかを確かめる。

samples は今まで通り CLI の生成物であり、デプロイ先ごとの検証に使う。
hono-cloudflare の `src/oidc-provider` は、`apps/hono/src/oidc-provider` から memory と kv の db ディレクトリを抜き、`db/index.ts` を sql で描画したものと一致するはずである。
これを drift check の不変条件として置く。

express と fastify は source を持たず、今と同じく hono から WebRouter 置換で派生させる。
素の Express の作法で出したくなったときは、`apps/express/` を動くアプリとして追加して registry に登録できる構成にしておく。

Next.js 側では、どのファイルがどの機能に属するかを route group で表す。
route group は URL に影響しない App Router 公式の仕組みなので、作法を崩さずにパスから所有者を読み取れる。
ルートを持たない機能ロジックは `_oidc-provider/features/<id>/` に置き、こちらもパスで所有者が分かる。

## 機能ディレクトリの中身

各機能ディレクトリは、機能の記述子を返す一ファイルを持つ。
記述子は、その機能が base のどこに差し込まれるかを宣言する。
PAR の例を示す。

```typescript
// features/par/feature.ts
import { defineFeature } from '../feature.js';
import { parApp } from './route.js';
import { parStore } from './store.js';
import { resolvePushedRequest } from './resolve-pushed-request.js';

/** EXPERIMENTAL — Pushed Authorization Requests (RFC 9126). */
export const par = defineFeature({
  id: 'par',
  routes: [{ path: '/par', app: parApp, methods: ['POST'], cors: 'protected' }],
  discovery: (issuer) => ({
    pushed_authorization_request_endpoint: `${issuer}/par`,
    require_pushed_authorization_requests: false,
  }),
  context: { parStore },
  authorize: { requestResolvers: [resolvePushedRequest] },
});
```

base 側は有効な機能の配列からマウント、メソッドガード、discovery を組み立てる。

```typescript
// app.ts
for (const route of routesOf(features)) app.route(route.path, route.app);

// endpoints/discovery/steps/build-metadata.ts
const metadata = { ...basicOpMetadata(issuer), ...discoveryOf(features, issuer) };
```

記述子が宣言できる差し込み箇所を**フック**と呼ぶ。
フックは固定集合とし、routes、discovery、context、config、token の grants と grantValidators と issuers、authorize の requestResolvers と responseModes、introspection の responders、loginMethods の 11 種類から増やさない前提に置く。
現在の 495 箇所の分岐を読んだ限りでは、機能が核エンドポイントへ食い込む場所はこの集合に収まる見込みである。
実際に収まるかは、進め方の第一段階で hono の生成物を組み替えるときに確かめる。

base 側の規則は一つで、base は `features/` と experimental パッケージを import しない。
分岐の材料になる型は base に置き、実装は機能側に置く。
この規則は lint で機械的に確かめる。

## 生成結果の四つのケース

同じ Hono のアプリから、指定によって何が出てくるかを四つのケースで示す。

### 素の Basic OP だけを出す場合

stable の任意機能をすべて外す。

```
maronn-oidc generate hono --disable pkce --disable introspection --disable revocation --disable refresh-token --disable request-object
```

`features/` 配下に機能ディレクトリは入らず、描画される一覧は空配列になる。

```typescript
// features/enabled.ts
import type { Feature } from './feature.js';
export const features: readonly Feature[] = [];
```

### 既定で生成する場合

core にある任意機能の五つがオンになる。

```
maronn-oidc generate hono
```

```typescript
// features/enabled.ts
import { pkce } from './pkce/feature.js';
import { introspection } from './introspection/feature.js';
import { revocation } from './revocation/feature.js';
import { refreshToken } from './refresh-token/feature.js';
import { requestObject } from './request-object/feature.js';
export const features = [pkce, introspection, revocation, refreshToken, requestObject] as const;
```

### experimental を足す場合

```
maronn-oidc generate hono --enable par --enable token-exchange
```

`features/par/` と `features/token-exchange/` が加わり、一覧に二行増える。
registry の `packages` から experimental パッケージのインストール案内が出る。
token エンドポイントでは、今の生成物にある五つの dispatch 文が一つのループになる。

```typescript
    // [authenticate-client] Authenticate the client — OAuth 2.1 §2.3
    const { tokenClient, authenticatedClientId } = await authenticateTokenClient(c, params, authorization);

    // [dispatch-feature-grants] token-exchange / device_code / CIBA / ID-JAG はここで応答して終わる
    for (const grant of tokenGrantsOf(features)) {
      const answered = await grant(c, { params, tokenClient, authenticatedClientId });
      if (answered) return respondToken(c, answered);
    }

    // [validate-grant-type] Validate grant_type — RFC 6749 §5.2
    const grantType = validateTokenGrantType(params, tokenClient, grantTypesOf(features));
```

Next.js で同じ指定をすると、`(par)/par/route.ts` が Route Handler のまま加わり、`_oidc-provider/features.ts` に `par` が一行増える。

### google-login を足す場合

```
maronn-oidc generate express --enable google-login
```

`features/google-login/` に `POST /login/google` のルートと記述子が入る。
ログイン画面は `loginMethodsOf(features)` を並べるので、Google のボタンは機能側が持つ。

```typescript
export const googleLogin = defineFeature({
  id: 'google-login',
  routes: [{ path: '/login/google', app: googleLoginApp, methods: ['POST'] }],
  loginMethods: [googleSignInButton],
});
```

registry には必要パッケージと対応ランタイム（Node.js のみ）を持たせ、インストール案内と Cloudflare への警告を CLI が出す。

## パイプラインの内側に入る任意のロジック

機能が独立したエンドポイントで済むなら、前節の形で足りる。
難しいのは、token エンドポイントのような既存のパイプラインの内側にロジックを足し、しかもそれを任意で切り替えたい場合である。
この場合も base に `if (features.x)` は書かず、次の順番で当てはめる。

### 実行時の設定で済む場合

生成コードは常にそのロジックを含み、`config.ts` の boolean で実行時に分岐する。
直近の acr_values 検証を任意にしたいなら、既定値に `validateAcrValues: true` を足し、ステップ内で `if (config.validateAcrValues)` と書く。
CLI は関与しない。
「core を直したが任意にしたい」の大半はここに落ちる。
生成時のトグルへ昇格させるのは、依存パッケージ、エンドポイントやファイル、ストア、あるいは base を汚すほどの行数のいずれかが増えるときに限る。
PKCE はこの基準に照らせば実行時の config で済む形をしているが、例外として introspection や revocation と同じ機能ディレクトリにする。
その理由は「生成時に切り替える機構が要るから」ではない。
PKCE は本来必須にすべき機能であり、外す必要があるのは OpenID Certification の一部のテストケースを通すときに限られるからである。
実行時の config に「PKCE を外す」スイッチを常設すると、生成物をそのまま運用する利用者がそのスイッチを使える状態になる。
機能ディレクトリにしておけば、`--disable pkce` で生成したときだけその緩和が生成物に入り、既定の生成物には緩和の入口そのものが存在しない。
`features/pkce/` の中身は PKCE を必須にする側であり、config フックで `allowNonPkceAuthorizationCodeFlow: false` を寄与する。
base は code_challenge が付いた要求の照合と public client への PKCE 要求を常に含み、機能ディレクトリが confidential client にも PKCE を要求する部分を足す。
`--disable pkce` で生成すれば今の緩和（confidential client の非 PKCE 要求のみ許可）と同じ挙動になる。

### 既存パイプラインにステップを足す場合

pipeline.ts は全機能オンの実コードであり、各ブロックの先頭行が所有者を名乗る。
この形を**所有者付きブロック**と呼ぶ。
機能がオフのとき、CLI はそのブロックを消し、不要になった import を消し、後続が読む値があれば既定値を置く。
これは `--flow` のステップ除去と同じ機構なので、機能ごとの生成コードは要らない。

```typescript
// apps/hono/src/oidc-provider/endpoints/introspection/pipeline.ts
    // [resolve-token] Resolve the presented token — RFC 7662 §2.1
    const introspection = await resolveIntrospectedToken(c, params, client);

    // [respond-as-jwt] (feature: jwt-introspection-response) Accept が JWT なら署名して応答 — RFC 9701 §4
    const jwtResponse = await respondIntrospectionAsJwt(c, introspection, client);
    if (jwtResponse) return jwtResponse;

    // [respond] Respond — RFC 7662 §2.2
    return respondIntrospection(c, introspection);
```

関数本体とステップの meta は機能側に置く。

```typescript
// apps/hono/src/oidc-provider/features/jwt-introspection-response/steps/respond-as-jwt.ts
export const meta = step({
  id: 'respond-as-jwt',
  endpoint: 'introspection',
  feature: 'jwt-introspection-response',
  kind: 'respond',
  spec: 'RFC 9701 §4',
  consumes: ['introspection', 'client'],
  produces: [],
});
export async function respondIntrospectionAsJwt(c, introspection, client): Promise<Response | undefined> { ... }
```

### 既存ステップの中身を変える場合

base のステップに**任意入力**を一つ足し、機能ステップがその値を作る。
DPoP で access token に `cnf` を載せたい場合、base の access token 発行ステップに `confirmation?: AccessTokenConfirmation` を足す。
型は base が宣言し、値は DPoP の機能ステップが produces する。

```typescript
// base: endpoints/token/steps/issue-access-token.ts
export async function issueAccessToken(c, { signingKey, subject, validatedRequest, issuedAt, acr, confirmation }: IssueAccessTokenInput) {
  const payload = buildAccessTokenPayload({ ..., ...(confirmation ? { cnf: confirmation } : {}) });
```

DPoP がオフなら CLI が `const confirmation = undefined;` を置き、base の分岐は到達しないまま残る。
現在の JARM が `jarmResponse` を後続へ渡している形と同じである。

### 登録の形をしたものを足す場合

前節の 11 種類のフックを使う。
新しい種類を足すのは core 側のプルリクエストであり、上の三段で表せないときの最後の手段にする。

### この方式の限界

限界は二つある。
ブロックは文の単位なので、base の `if` の内側に機能のブロックは置けない。
base ステップの途中に割り込みたいなら、そのステップを二つに割る変更を先に出すか、実行時の config に倒す。
もう一つは、任意入力が増えすぎると base の関数が引数だらけになることで、一機能につき一つまでを目安にレビューで止める。

## CLI が generate で行うこと

1. registry でフラグを解決する。requires、tier、フレームワーク対応を見る。
2. ファイルを選ぶ。base と `features/<id>/**` と `db/<kind>/**`。Next.js は `(<id>)/**` と `_oidc-provider/features/<id>/**`。
3. データファイルを四つ描画する。manifest、`features/enabled.ts`、`scopes.ts`、`db/index.ts`。
4. import 指定子を書き換える。core のパッケージ名だけ。Next.js は書き換え無し。
5. 機能がオフの所有者付きブロックを消す。`--flow` のときはさらに並べ替える。

現在の catalog.ts は 1,856 行のデータだが、各ステップの meta を CLI のビルドで apps から集めて catalog.json に焼けば、`graph` と `--flow` はそれを読むだけになる。
コードと図が乖離する余地が無くなる。

CLI の規模は、数万行の文字列から数千行の生成器へ縮む。
機能固有のコードは CLI に入らない。

## テストと検証

| 層 | 対象 | いつ |
|---|---|---|
| 単体 | steps と features の関数 | PR ごと |
| 型 | 生成マトリクス。既定、全オフ、各機能単独、db 3 種、並べ替え 1 つ | PR ごと、数十秒 |
| 構造 | 抽出範囲の全ファイルが base か 1 機能か 1 db 種に属するか除外に挙がっていること、features 間の import 禁止、requires の整合、consumes と produces の整合 | PR ごと |
| E2E | apps の dev サーバ。hono と Next.js、全機能オン | PR ごと |
| デプロイ | samples の drift と typecheck は PR ごと、E2E は nightly | |

組合せが壊れる経路は、機能ディレクトリが他の機能を requires 無しで import するか、フックの型が合わないかのどちらかに絞られる。
どちらも型検査と lint で検出できるため、組合せごとの E2E は要らない。
PR ごとの E2E を apps へ向けるので、wrangler や sqlite を使うのは samples の nightly だけになる。

## 第三者のプルリクエストがどう変わるか

| やりたいこと | 触る場所 | 現在 |
|---|---|---|
| token エンドポイントのバグ修正 | `endpoints/token/steps/` の該当ファイルと隣のテスト。Next.js も同名ファイル | 文字列断片を直し、samples 4 つを再生成してコミット。単体テスト不可 |
| 新しい experimental 機能（例: DPoP） | hono と nextjs に機能ディレクトリ、所有者付きブロックの挿入、任意入力 1 つ、registry に 1 エントリ、E2E spec 1 本 | 5 から 7 ファイルの文字列に分岐を差し込む。DCR 追加は 7 ファイル 666 行 |
| ログイン画面の見た目 | `views.tsx` か `login/page.tsx` を直接編集し `pnpm dev` で確認 | 文字列の中の JSX |
| DB の列追加 | `db/sql/` の schema と stores | 1,694 行の文字列ファイル |
| 新フレームワーク（素の Express） | `apps/express/` を動くアプリとして追加し registry に登録。対応機能は部分的でよい | 事実上不可能 |

差分が実コードなので、レビュアーは生成物を頭の中で展開せずに読める。

## 進め方

1. hono サンプルの生成物から `apps/hono` を起こし、features と steps に割ってフックを入れる。dev サーバと E2E をここへ向ける。ここまでで「実コードを直してテストできる」状態になる。
2. 新 CLI を書く。コピー、データ 4 ファイル、import 書き換え、マトリクス型検査。
3. `graph` と `--flow` を meta 由来の catalog.json へ載せ替える。
4. Next.js サンプルの生成物から `apps/nextjs` を起こす。
5. 旧 generator を削除し、samples を再生成する。

これは移行ではなく作り直しであり、数週間規模である。
テンプレートの変更頻度が高いので、長期ブランチではなく main への小さな PR で進める。

## 懸念点とトレードオフ

- 可読性の代償が二つある。hono の `app.ts` は 16 行の明示的なマウントが一つのループになり、token は五つの dispatch 文が一つのループになる。代わりに、生成後に機能を外したい利用者はディレクトリを消して一覧の一行を消すだけで済む。現在は 5 ファイルを探して回る作業である。
- フックによる間接化が一段入るため、生成物を読む側に前提が一つ増える。フックの種類を固定集合にし、`graph` で箱ごとに表示できる状態を保つことで抑える。
- hono と Next.js で同じロジックを二か所に持つ。バグ修正は二つのファイルを直すことになる。これは Next.js の作法を守る選択の対価であり、共通化で可読性を落とすより軽いと判断した。
- 所有者付きブロックの除去と import の整理は、CLI がコードを操作する唯一の箇所になる。文単位にとどめ、マトリクス型検査で確かめる。

## 未決事項

- 所有者付きブロックの印の正確な構文。
- Next.js でも所有者付きブロックの除去を受け付けるか。並べ替えは非対応のままとする。
- `refresh-token` を機能ディレクトリにするか、実行時の config に倒すか。token パイプラインのフック数に影響する。
