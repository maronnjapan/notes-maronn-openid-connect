# `offline_access` scope の付与条件設計（`isOfflineAccessGranted` 拡張ポイントの整理）

## ステータス

🟡 設計ハブ / 既存実装あり・ドキュメント不足

> 追記: §4.3 と §5 が問題にしていた二系統ガード（`isOfflineAccessGranted` と
> `RegisteredClient.offlineAccessAllowed`）は方針 B の方向で解消済み。
> `OfflineAccessGrantedCallback` の context に `client` が渡るようになり、既定判定が
> `prompt=consent` とクライアント登録 `grant_types` の両方を見る。生成コードの
> `offlineAccessAllowed` フィルタは削除した。
> 経緯は `study-material/done/offline-access-grant-vs-client-grant-types-consistency.md`、
> 実装は `tasks/done/p1-refresh-token-issuance-requires-refresh-grant-registration.md` を参照。
> 本ファイルに残る課題は「代替条件の実装パターンをどう示すか」（方針 A / C）である。

## 1. このトピックで確認したいこと

- OpenID Connect Core 1.0 §11 が定める **`offline_access` scope** の付与条件は「`prompt=consent` を含むこと、または `other conditions for processing the request permitting offline access to the requested resources are in place`」と規定されている。後段の「その他の条件」は OP 実装の裁量に委ねられている。
- 本リポジトリは既に `defaultIsOfflineAccessGranted`（`prompt=consent` を必須とする安全側既定）と、利用者が差し替え可能な `isOfflineAccessGranted: OfflineAccessGrantedCallback` 拡張ポイントを実装している（`packages/core/src/authorization-request.ts:111-123`、`543-552`）。しかし study-material には **どんな代替条件が考えられるか・どう設計すべきか**の設計指針が無い。
- 関連する既存タスク・ファイル:
  - `tasks/done/p0-offline-access-prompt-consent.md`（`prompt=consent` 必須化の確定実装）
  - `tasks/p1-refresh-scope-offline-access-rotation.md`（ローテーション時の offline_access 取り扱い）
  - `study-material/refresh-token-rotation-replay-grace.md`（ローテーション誤検知緩和）
- 本ファイルは「拡張ポイントの**使い方**・**設計パターン**」をハブ化し、上記既存タスクには無い差分を提供する。
- なお「Refresh Token の発行そのものを `offline_access`（OIDC 固有 scope）に紐づけてよいか」という
  前段の適用範囲の論点は `study-material/oauth-only-authorization-request-openid-scope-policy.md` が扱う。
  本ファイルは「`offline_access` を**付与するかどうか**」に限定する。

## 2. 関連する仕様・基準

共通の Refresh Token / `offline_access` 仕様説明は重複させない。既存ファイルを参照のこと:

- `tasks/done/p0-offline-access-prompt-consent.md`: `prompt=consent` 必須化と無条件削除の根拠
- `tasks/p1-refresh-scope-offline-access-rotation.md`: ローテーション時の scope 縮小規則
- `study-material/refresh-token-rotation-replay-grace.md`: 再利用検知の誤検知緩和

本トピック固有の差分:

### 2.1 OIDC Core 1.0 §11 — `offline_access` 付与の条件

§11 は次のように規定:

> Use of this scope value MUST NOT cause the Refresh Tokens to be returned to the Client unless: ... the Authentication Request includes the `prompt` parameter with the value `consent`, OR ... other conditions for processing the request permitting offline access to the requested resources are in place that are sufficient to enable the OP to grant offline access.

整理:

- **MUST NOT** 条件: `prompt=consent` も「その他の条件」も無いまま `offline_access` を付与してはいけない。
- **MAY** 条件: 上記いずれかが満たされる場合のみ付与してよい。
- 「その他の条件」の例（informative）: ユーザー設定で「常にこのクライアントにオフラインアクセスを許可」とした記録、リソース所有者が事前に明示的に許可した実装固有の仕組み等。

### 2.2 本リポジトリの拡張ポイント設計

`OfflineAccessGrantedCallback` のシグネチャ（既存実装）:

```ts
export type OfflineAccessGrantedCallback = (
  request: AuthorizationRequestParams,
  context: { promptValues: string[] },
) => boolean | Promise<boolean>;
```

- 戻り値 `false` → core 側で `offline_access` を scope から除外（仕様 §11 の MUST NOT を遵守）。
- 戻り値 `true` → scope に維持。
- 既定実装 `defaultIsOfflineAccessGranted` は `promptValues.includes('consent')` のみで判定（安全側）。

### 2.3 既存 IdP の設計事例

| IdP | デフォルト挙動 | 差し替え経路 |
|---|---|---|
| Auth0 | `offline_access` 要求があれば常時付与（簡便側） | 管理画面で「Allow Offline Access」フラグ per-Client / per-API |
| Keycloak | `prompt=consent` 不要、クライアント設定で許可スコープに含める | Client Scope 設定 + ユーザー consent UI |
| Okta | scope 申告 + クライアント許可済みなら付与 | Client Refresh Token Policy |

本リポジトリは「`prompt=consent` 必須」既定だが、これは **本リポジトリの想定ユーザー（PoC 開発者）の安全側既定** として妥当。商用 IdP は利便性側にチューニングしているが、漏洩 RT の長期被害を考えると本リポジトリの選択は保守的で説明可能。

## 3. 参照資料

- OpenID Connect Core 1.0 §11 — https://openid.net/specs/openid-connect-core-1_0.html#OfflineAccess
- 本リポジトリ内: `packages/core/src/authorization-request.ts:111-123` (`OfflineAccessGrantedCallback` の型定義)
- 本リポジトリ内: `packages/core/src/authorization-request.ts:120-123` (`defaultIsOfflineAccessGranted` 既定実装)
- 本リポジトリ内: `packages/core/src/authorization-request.ts:543-552`（scope フィルタ適用箇所）
- 本リポジトリ内: `tasks/done/p0-offline-access-prompt-consent.md`（既定実装の決定根拠）

## 4. 現在の実装確認

### 4.1 拡張ポイント

```ts
// authorization-request.ts:128-134
export interface ValidateAuthorizationRequestOptions {
  isOfflineAccessGranted?: OfflineAccessGrantedCallback;
}
```

### 4.2 適用箇所

```ts
// authorization-request.ts:543-552
if (scope.includes('offline_access')) {
  const isGranted =
    options.isOfflineAccessGranted ?? defaultIsOfflineAccessGranted;
  const granted = await isGranted(params, { promptValues: prompt ?? [] });
  if (!granted) {
    const filtered = scope.filter((s) => s !== 'offline_access');
    scope.length = 0;
    scope.push(...filtered);
  }
}
```

### 4.3 sample / CLI

- `packages/sample/src/oidc-provider/routes/authorize.ts:127-130`: `validateAuthorizationRequest(params, clientResolver)` でオプション未注入 → 既定の `prompt=consent` 必須挙動。
- `packages/sample/src/oidc-provider/routes/authorize.ts:225-230`: `RegisteredClient.offlineAccessAllowed` フラグ参照あり。**ただし `validateAuthorizationRequest` のオプションには反映していない**。post-validation の段階で `offline_access` を除外する保険になっている。
- `RegisteredClient.offlineAccessAllowed` と `isOfflineAccessGranted` の関係が **二系統で交差している** → 設計上の冗長性と、もしどちらかが緩い設定だった場合の事故ポテンシャルがある。

## 5. 現在の実装との差分

満たしていること:

- ✅ §11 MUST NOT を遵守（`prompt=consent` 無し時は除外）。
- ✅ 利用者が独自条件で「その他の条件」を表現できる拡張ポイント存在。
- ✅ ローテーション時の scope 引き継ぎは別タスクで追跡中。

不足／確認が必要なこと:

- 🟡 **ユースケース別の設計指針が無い**: 拡張ポイントはあるが、「ユーザー設定 UI で許可された場合」「クライアント設定で許可された場合」等の **具体的な実装パターン**がドキュメント化されていない。
- 🟡 **二系統（`isOfflineAccessGranted` と `RegisteredClient.offlineAccessAllowed`）の整理**: 現状は両方を経由してフィルタするため、片方が「許可」でも片方が「不許可」なら最終的に除外される。安全側だが、利用者には認知負荷が高い。どちらかに一本化するか、明示的に「二重ガード」と説明するかの設計判断が要る。
- 🟡 **`RegisteredClient.offlineAccessAllowed` の取り出し経路**: `prompt=none` パスでは `clientResolver.findClient` を再呼び出ししてフィルタ判定している（`routes/authorize.ts:225-230`）。一方、通常パス（login → consent → code）ではどこでフィルタするかが不明瞭。
- 🟡 **`prompt=consent` 強制によるユーザー体験**: PoC 段階では同意画面が毎回出るのは煩雑。「初回のみ consent」「設定で記憶」等の挙動を試したい利用者にとって、`isOfflineAccessGranted` の使用例があると着手しやすい。
- 🟢 **ID Token / UserInfo 側への露出は無し**: `offline_access` は AT/RT 発行制御のみであり、ID Token のクレームには出ない。

セキュリティ観点:

- 利用者が `isOfflineAccessGranted: () => true` のような無条件許可を書くと、§11 MUST NOT 違反になる。**ドキュメントで明示的に警告**する必要がある。
- 「ユーザー設定で許可」を実装する場合、設定変更時に既存の発行済み RT を**失効**する判断が要る。これは別タスク（RT 絶対有効期限）と連動。

## 6. 改善・追加を検討する理由

価値:

- 拡張ポイントは存在するが、**使用例ドキュメントが無い**ことで利用者が `prompt=consent` 必須挙動に戸惑い、安全でない上書きをする/上書きできずに離脱する、いずれの方向にもリスクがある。
- 「責務の境界」（`RELEASE-v0.x-scope.md`）に従って「OP は安全側既定、独自ポリシーは利用者責任」を**明示する文書**を作ることで、ファネル設計（PoC → IDaaS 相談）の方向性と整合する。
- 二系統ガード（callback と `RegisteredClient`）の整理は、利用者の混乱を減らし、設計レビュー時の事故ポテンシャルを下げる。

導入難易度:

- 🟢 **コード変更最小**: 既存実装はそのまま。ドキュメントとサンプルコードの整備が中心。
- 🟡 **二系統ガード整理**: `routes/authorize.ts` の `offline_access` 取り扱いを `validateAuthorizationRequest` への callback 注入に一本化することは可能。ただし `clientResolver.findClient` を二重呼び出ししないための工夫が要る。
- 🟢 **テストの充実**: 各パターン（`prompt=consent` のみ / クライアント許可済み / ユーザー設定許可 / 双方無し）のテストケースが揃うと利用者の参考になる。

実装しない場合のリスク:

- 利用者が `prompt=consent` 必須挙動に苦戦して `isOfflineAccessGranted: () => true` を書き、安全側既定を破壊する。
- 二系統ガードのまま放置し、片方を変更したつもりがもう片方で除外されるケースで「動かない」と判断され離脱。

## 7. 実装方針の候補

### 方針A（ドキュメント中心）

- `study-material` 配下に「`isOfflineAccessGranted` 使用例パターン集」を追加（本ファイルがそれ）。
- `OfflineAccessGrantedCallback` の JSDoc に推奨パターンと「無条件許可は §11 違反」の警告を追記。
- CLI 生成テンプレートに `isOfflineAccessGranted` の使用例コメントを入れる。

### 方針B（二系統ガード整理）

- `routes/authorize.ts` の `offlineAccessAllowed` フィルタを廃止し、`isOfflineAccessGranted` callback に統合。
- callback の第2引数に `clientResolver` 経由のクライアント情報を渡せるよう拡張（または callback シグネチャに `client: ClientInfo` を追加）。
- 既存テストの動作を保つことを TDD で確認。

### 方針C（ユースケース別ヘルパー追加）

- `core` に複合判定ヘルパーを追加:
  ```ts
  export function createConsentBasedOfflineAccess(): OfflineAccessGrantedCallback;
  export function createClientFlagBasedOfflineAccess(
    clientResolver: ClientResolver
  ): OfflineAccessGrantedCallback;
  export function combineOfflineAccessGuards(
    ...guards: OfflineAccessGrantedCallback[]
  ): OfflineAccessGrantedCallback;
  ```
- 利用者は組み合わせて適用できる。`combineOfflineAccessGuards` は AND セマンティクスで二重ガードを明示。

### 方針D（現状維持）

- 既存実装のまま。本ファイルをハブとして残し、利用者が必要に応じて読む。
- CLI / sample の挙動は変更しない。

判断材料:

- 方針 A は実装コスト最小で利用者に最も効果がある。
- 方針 B は二系統ガードの設計上の冗長性を解消するが、callback シグネチャの拡張が breaking change を伴う。バージョンアップに紐付ける必要がある。
- 方針 C は overkill 感があるが、組み合わせの明示は教育効果が高い。
- 方針 D は実装コストゼロだが、利用者の混乱が残る。

## 8. タスク案

- [ ] 方針 A / B / C / D のいずれを採るか人間が判断する。
- [ ] 方針A採用時:
  - [ ] `authorization-request.ts` の `OfflineAccessGrantedCallback` JSDoc に「無条件 `true` は §11 MUST NOT 違反」警告を追記。
  - [ ] CLI 生成テンプレート（`packages/cli/src/frameworks/hono/templates.ts`）に `validateAuthorizationRequest` 呼び出しの隣に `isOfflineAccessGranted` 使用例コメントを追加。
  - [ ] 本ファイル §2.3 の IdP 比較表を README / ドキュメント入口に反映するかを判断。
- [ ] 方針B採用時:
  - [ ] `OfflineAccessGrantedCallback` シグネチャを `(request, context: { promptValues, client })` に拡張。
  - [ ] `routes/authorize.ts` の `offlineAccessAllowed` ベースフィルタを削除し、callback 注入に一本化。
  - [ ] Breaking change を `RELEASE-v0.x-scope.md` のメジャーバージョン区切りに合わせて配置。
- [ ] 方針C採用時:
  - [ ] `createConsentBasedOfflineAccess` / `createClientFlagBasedOfflineAccess` / `combineOfflineAccessGuards` を `core` に追加し index.ts でエクスポート。
  - [ ] TDD で各ヘルパーの単体テストを追加。
- [ ] 利用者向けに「`offline_access` 付与条件のカスタマイズパターン」ガイドを README に追加するかを判断。
- [ ] 関連する既存タスク（`tasks/p1-refresh-scope-offline-access-rotation.md` / `tasks/p1-refresh-token-absolute-lifetime.md`）と本ファイルの相互参照リンクを整理。
