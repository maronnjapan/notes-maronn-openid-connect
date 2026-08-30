# Cross-App Access / ID-JAG 実装解説

- **feature-id**: `id-jag`
- **準拠仕様**: draft-ietf-oauth-identity-assertion-authz-grant-04（2026-05 版）、RFC 8693、RFC 7521 / RFC 7523、RFC 8414、RFC 8725
- **実装場所**: `packages/experimental/src/id-jag/`
- **有効化**: `maronn-oidc generate <framework> --enable id-jag`
- **要件文書**: `tasks/experimental/id-jag/`（specification.md / understanding-guide.md / sources.md）

## 機能の概要

**Cross-App Access（XAA）** は、SSO で同じ IdP を信頼する 2 つのアプリケーションの間の API アクセスを、その IdP が仲介するパターンである。
従来この連携は、アプリ B の認可画面へユーザーをリダイレクトする個別の OAuth 同意として行われ、IdP からは見えなかった。
XAA では、アプリ A が手元の ID トークンを IdP のトークンエンドポイントで **ID-JAG（Identity Assertion JWT Authorization Grant）** に交換し（RFC 8693 Token Exchange）、それをアプリ B 側の認可サーバーへ JWT Bearer Grant（RFC 7523）として提示してアクセストークンを得る。
ユーザーの追加同意は発生せず、どのアプリ間アクセスを許すかは IdP 側の許可リストが決める。

本機能は 1 つの生成 OP に 2 つの役割を追加する。

- **発行側（IdP）**: Token Exchange grant で `requested_token_type=urn:ietf:params:oauth:token-type:id-jag` を受け、自 OP 発行の ID トークンを検証して ID-JAG を発行する
- **受領側（リソースアプリの認可サーバー）**: `urn:ietf:params:oauth:grant-type:jwt-bearer` grant で、信頼設定済みの外部 IdP が署名した ID-JAG を検証し、自 OP のアクセストークンを発行する

生成 OP を 2 インスタンス起動して互いを設定で信頼させると、XAA の 4 ステップ（SSO、Token Exchange、ID-JAG 提示、API アクセス）を完結して再現できる。E2E テストが実際にその構成で検証している。

### ユースケース

- 「アプリ A がアプリ B のデータをユーザーの再同意なしで読む」エンタープライズ SSO 拡張構成を、IdaaS 契約前に手元で再現する
- AI エージェントが企業 IdP の仲介で外部ツールの API トークンを取得する構成（draft Appendix A.4）の検証
- Token Exchange と JWT Bearer Grant の連鎖をプロトコルレベルで確認する学習目的の PoC

### 実装スコープと非目標

subject_token は自 OP 発行の ID トークンを必須対応とし、設定（`allowRefreshTokenSubjects`、既定 true）で**自 OP 発行の refresh token** も受ける（draft §4.3 の MAY）。
ID トークンの期限が切れても、SSO で受け取っていた refresh token から SSO をやり直さずに新しい ID-JAG を要求できる。
また `allowActorTokens`（既定 false の opt-in）を有効にすると **actor_token**（本 OP 発行・認証クライアント宛ての ID トークン）を受け、「誰が subject の代理として振る舞うか」を ID-JAG の `act` クレーム（RFC 8693 §4.1）に記録する。
draft は actor の処理規則を定義していない（§9.7 が拡張の指針を示すのみ）ため、これは指針に沿った本機能独自の拡張であり、既定では無効にしてある。
actor_token の種別は ID トークンを組込みで検証し、それ以外の種別（RFC 8693 は任意の token type identifier を許す）は、内容検証を担うデプロイ側リゾルバ（`actorTokenResolver`）を設定したときだけ受ける。
SAML assertion の subject、`sub_id`（SAML NameID）、`authorization_details`（RAR）、DPoP による sender-constraining、step-up authentication、テナント系クレームは非目標のままで、黙って無視すると権限の表明がずれるパラメータ（無効時の `actor_token` / `authorization_details`）は `invalid_request` で明示的に拒否する。

ID-JAG の `client_id` クレームには、IdP で認証したクライアントの client_id をそのまま入れる。
draft §5 はリソース AS 側で別の client_id を使う対応表も認めるが、初期実装は両 AS で同一 client_id を使う前提に固定した（Client ID Metadata Document 型の共有名前空間を想定した簡略化）。

`jti` によるリプレイ拒否ストアは持たない。
draft §4.4.3 は「アクセストークン失効後に同じ ID-JAG を再提示してよい（ID-JAG がリフレッシュトークンの代替になる）」と定めており、有効期間内の再提示は仕様上の正当な利用形態だからだ。
束縛はクライアント認証、`client_id` クレームの一致、短い有効期間（デフォルト 300 秒）が担う。

## 実装の設計方針

**既存 experimental 機能とコードを共有しない。**
Token Exchange の grant_type URN は既存の `token-exchange` 機能と重なるが、定数も含めて共有せず、ディスパッチ順序で分離する。
生成コードは「`requested_token_type` が ID-JAG のときだけ」本機能の発行分岐へ入り、それ以外は既存の token-exchange 分岐（有効時）か `unsupported_grant_type` に落ちる。
`--enable id-jag` 単独でも `--enable token-exchange` との併用でも動き、片方の変更が他方へ波及しない。

**受信 JWS の検証は事前登録鍵のみで行う。**
発行側の subject_token（ID トークン）検証は core の `validateIdTokenHint` に委譲する。署名検証、iss / aud / exp / iat、`alg: none` の拒否、外部鍵取得ヘッダ（jku / jwk / x5u / x5c）の拒否という RFC 8725 対策一式をそのまま得られる。
受領側の assertion 検証は本モジュール内の自前実装だが、鍵の選択規則（kid 優先、alg 一致、鍵ごとの alg ピン留め）は core と同じにし、鍵は必ず注入された信頼 IdP の JWKS から選ぶ。
assertion の内容から鍵の取得先を導出する経路は存在せず、jwks_uri の fetch は生成コード側の静的設定からだけ行われる（SSRF と鍵差し替えの防止）。

**ID-JAG の署名は JARM と同じ自前 compact JWS 生成で行う。**
core の非公開な低レベル署名ヘルパーには依存せず（core 無変更の維持）、alg は RS256 固定、`typ: oauth-id-jag+jwt` を必ず付ける（RFC 8725 §3.11 の explicit typing。受領側の必須検証項目でもある）。

**信頼設定はデフォルト空の fail-safe。**
発行側の `allowedAudiences` も受領側の `trustedIdentityProviders` も空で生成され、設定するまで ID-JAG は 1 枚も発行されず 1 枚も受理されない。
XAA にはユーザーの同意画面が無いので、許可リストへの追加は「そのアプリ間アクセスをユーザー全員に代わって許可する」操作になる。この意味は生成コードのコメントにも明記した。

**refresh token subject の検証は refresh grant の完全な再利用にする。**
draft §4.3.3 は RT subject を「通常の refresh_token grant と同じ方法で検証しなければならない」と定める。
本機能はこれを、core の refresh grant ステップ関数（解決、rotation 再利用検知、クライアント束縛、期限、online RT のセッション生存確認）をそのまま呼ぶことで文字どおり満たす。
したがって rotation 済み RT の再提示は refresh grant と同じく token family の失効を発火させ、検証水準に差が生まれない。
RT は消費しない（rotation しない）。この交換は refresh grant ではなく、同じ RT で ID-JAG を繰り返し要求できることが draft §4.4.3 の更新パスの前提だからだ。
加えて `openid` scope を持たない grant の RT は拒否する。ID トークン（Identity Assertion）が存在し得ない grant の RT に「Identity Assertion の代替」は成立しない。

**actor_token は opt-in で、subject と同じ検証を通す。**
draft §9.7 は actor 拡張に「無関係な、あるいはより信頼の低いトークンの持ち込みで actor の権威を過大表明させない」ことを求める。
本機能は actor_token を subject と同じ「本 OP 発行・認証クライアント宛ての ID トークン」に限定し、同じ `validateIdTokenHint` で検証して、`act` には actor の `sub` だけを載せる（属性の不要な越境を避ける）。
受領側は ID-JAG の `act` を構造検証して、発行するアクセストークンの payload と store metadata へ必ず引き継ぐ。
黙って落とすと「誰が代理で動いたか」の記録が消え、委譲が impersonation に見えてしまうため、malformed な `act` は `invalid_grant` で拒否する。

**独自種別の actor_token は「構造はライブラリ、内容はリゾルバ」で受ける。**
RFC 8693 の actor_token_type は ID トークンに限らないため、id_token 以外の種別は `actorTokenResolver`（デプロイ側フック）の注入で受けられる。
ライブラリはリクエスト構造（対応規則・非空・opt-in の gate）とリゾルバ戻り値の構造（`sub` 必須、`sub` / `act` 以外の属性の除去、ネスト同形）だけを検証し、トークン内容の検証（署名・失効・帰属）はリゾルバの責務とする。
id_token の組込み検証はリゾルバでは差し替えられず、リゾルバの `null` は固定文言の `invalid_request`、`IdJagError` は透過、他の例外は `server_error` になる（デプロイ側のバグをクライアント起因に見せない）。

**同一トラストドメイン内の利用は二重に禁止する。**
draft §9.3 の「IdP は自分が発行した ID-JAG に対して同一ドメイン内でアクセストークンを発行してはならない」を、発行側（`audience` が自 issuer なら `invalid_target`）と受領側（`iss` が自 issuer なら `invalid_grant`）の両方で検証する。片方の設定ミスがあっても抜け道にならない。

**受領側のアクセストークン寿命は ID-JAG の残存期間で cap しない。**
token-exchange 機能は交換後トークンの寿命を subject の残存期間で抑えるが、ID-JAG は逆に「短命な grant から通常寿命のアクセストークンが出る」のが正しい（draft の例でも grant 300 秒に対しトークン 86400 秒）。認可コードが 5 分で切れても、そこから出たトークンが 1 時間生きるのと同じ関係である。

エラー写像は 2 系統になる。
発行側は RFC 8693 §2.2.2 に従い `invalid_request` / `invalid_target` / `invalid_scope` / `unauthorized_client`、受領側の assertion 不備は RFC 7521 §4.1 の `invalid_grant` を使う。
オラクル排除の固定文言は 2 つある。発行側の subject_token 検証失敗は失敗種別を区別せず、受領側では「iss が信頼リスト外」と「署名検証失敗」を同一文言にして、応答から信頼 IdP リストを探索できないようにしている（draft §9.4 が discovery でのリスト開示を禁じるのと同じ趣旨）。

## 実装コードの全文と解説

モジュールは 4 ファイルで、core と同じ「合成関数＋ステップ関数」の二層構成である。
生成コードは合成関数（`processIdJagIssuanceRequest` / `processIdJagRedemptionRequest`）を呼ぶが、利用者はステップ関数を 1 つずつ呼ぶ形に書き換えて、検証を差し替えたり削除したりできる。

### errors.ts（エラー型と固定文言）

`IdJagError` を core の `TokenError` と別クラスにするのは token-exchange と同じ理由で、core の closed な enum に `invalid_target` が無いためである。
オラクル排除用の固定文言 2 つもここに置き、実装とテストと生成 conformance テストが同じ定数を参照する。

```typescript
/**
 * Identity Assertion Authorization Grant (ID-JAG) — エラー型
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * 発行側（IdP、Token Exchange 分岐）と受領側（リソース AS、jwt-bearer 分岐）の
 * 両方がこのエラーを投げる。どちらもバックチャネル専用（リダイレクトは存在
 * しない）で、常に 400 + JSON で返す。401 になるのはクライアント認証失敗
 * （`invalid_client`）だけであり、それは分岐より前の共有認証パイプライン
 * （core の `TokenError`）が担当する。
 *
 * core の `TokenErrorCode` は closed な enum で `invalid_target` を含まないため、
 * core 無変更の制約下では core の `TokenError` に相乗りできない
 * （token-exchange 機能の `TokenExchangeError` と同じ帰結）。
 */
import { sanitizeErrorDescription } from '@maronn-openid-connect/core';

/**
 * ID-JAG のエラーコード。
 *
 * - 発行側（RFC 8693 §2.2.2 / RFC 6749 §5.2）: invalid_request /
 *   unauthorized_client / invalid_scope / invalid_target
 * - 受領側（RFC 7521 §4.1）: assertion の不備は invalid_grant、それ以外は
 *   invalid_request / unauthorized_client / invalid_scope
 */
export type IdJagErrorCode =
  | 'invalid_request'
  | 'invalid_grant'
  | 'unauthorized_client'
  | 'invalid_scope'
  | 'invalid_target';

export class IdJagError extends Error {
  readonly code: IdJagErrorCode;
  readonly errorDescription: string;

  constructor(code: IdJagErrorCode, errorDescription: string) {
    // RFC 6749 §5.2: error_description は安全な文字集合に限定する。
    const sanitized = sanitizeErrorDescription(errorDescription);
    super(sanitized);
    this.name = 'IdJagError';
    this.code = code;
    this.errorDescription = sanitized;
  }

  /** 本エラーは常に 400（401 は分岐前の共有パイプラインが返す）。 */
  get statusCode(): 400 {
    return 400;
  }
}

/**
 * 発行側で subject_token（ID トークン）の検証に失敗したときの固定 error_description。
 *
 * 署名不正・iss 不一致・aud（クライアント）不一致・期限切れ・構造不正を区別しない。
 * 応答からトークンの有効性を推測できる「オラクル」を作らないための意図的な設計で、
 * token-exchange 機能の subject_token 解決失敗と同じ方針（文言も同一）。
 */
export const SUBJECT_TOKEN_INVALID_DESCRIPTION =
  'The provided subject_token is not valid';

/**
 * 発行側で actor_token（ID トークン）の検証に失敗したときの固定 error_description。
 *
 * {@link SUBJECT_TOKEN_INVALID_DESCRIPTION} と同じオラクル排除方針で、どの
 * パラメータが不正だったかだけを伝え、失敗理由（署名、iss、aud、期限）は
 * 区別しない。token-exchange 機能の actor_token 解決失敗と同じ文言。
 */
export const ACTOR_TOKEN_INVALID_DESCRIPTION =
  'The provided actor_token is not valid';

/**
 * 受領側で「iss が信頼リスト外」と「署名検証失敗」の両方に使う固定 error_description。
 *
 * 両者を区別すると、応答の違いから信頼済み IdP のリストを外部から探索できて
 * しまう（ID-JAG draft §9.4 が discovery でのリスト開示を禁じるのと同じ趣旨）。
 */
export const ASSERTION_UNTRUSTED_DESCRIPTION =
  'The assertion issuer is not trusted or the assertion signature is invalid';
```

### issue-id-jag.ts（発行側: IdP の役割）

発行側の中心は subject、actor、audience、scope の検証である。
subject_token の検証は種別で分かれる。ID トークン（`resolveIdJagSubject`）は core の `validateIdTokenHint` に委譲し、draft §4.3.3 の MUST である「assertion の aud がクライアント認証の client_id と一致すること」を `expectedAud` の指定で満たす。他クライアント宛てに発行された ID トークンの持ち込みは、ここで固定文言の `invalid_request` になる。
refresh token（`resolveIdJagSubjectFromRefreshToken`）は core の refresh grant ステップ関数を再利用し、subject のクレーム（sub / auth_time / acr / amr）を RT の保存済み grant 文脈から組み立てる。
actor_token は種別で分かれる。ID トークン（`resolveIdJagActor`）は subject と同一の検証を通し、`act` に載せる値（`{ sub }`）だけを返す。それ以外の種別（`resolveIdJagActorFromCustomToken`）はデプロイ側の `actorTokenResolver` へ内容検証を委譲し、戻り値を構造検証・正規化（`sub` / `act` 以外の属性の除去）してから `act` にする。id_token 種別がリゾルバへ渡ることはない（組込み検証の非バイパス）。
audience の検証（`validateIdJagAudience`)は許可リストと自 issuer 除外の 2 段で、scope の検証（`validateIdJagScope`）は `allowedScopes` 未設定なら素通しにする（scope の意味論はリソース AS のドメインに属し、受領側でも同じ縮小ポリシーが働くため）。

```typescript
/**
 * Identity Assertion Authorization Grant (ID-JAG) の発行 — IdP 側
 * draft-ietf-oauth-identity-assertion-authz-grant-04 §3 / §4.3
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * 既存トークンエンドポイントの Token Exchange grant（RFC 8693）のうち、
 * `requested_token_type=urn:ietf:params:oauth:token-type:id-jag` の要求を処理する。
 * subject_token として自 OP 発行の ID トークン（設定により refresh token も。
 * draft §4.3 の MAY）を受け取り、検証のうえで別トラストドメインのリソース AS
 * 宛ての署名付き authorization grant JWT（ID-JAG）を発行する。
 * actor_token（本 OP 発行の ID トークン）の受理を有効化すると、発行する ID-JAG に
 * `act` claim（RFC 8693 §4.1 / draft §3.1 OPTIONAL）を記録できる。id_token 以外の
 * actor_token 種別は、内容検証を担うデプロイ側リゾルバ
 * （{@link IdJagActorTokenResolver}）を注入したときだけ受ける。
 *
 * core と同じ「合成関数＋ステップ関数」の二層構成とし、CLI 生成コードは
 * ステップ関数を順に呼び出して検証を差し替え・削除できるようにする。
 * 既存の token-exchange 機能とは grant_type URN を共有するが、コードは共有
 * しない（experimental 機能同士の独立性優先。重複を許容する方針）。
 *
 * ID-JAG の署名は JARM の応答 JWT と同じく Web Crypto API による自前の
 * compact JWS 組み立てで行い、core の非公開な低レベル署名ヘルパーには
 * 依存しない（core 無変更の維持）。
 */
import {
  IdTokenHintError,
  TokenError,
  generateRandomString,
  resolveRefreshToken,
  validateIdTokenHint,
  validateRefreshTokenClient,
  validateRefreshTokenExpiration,
  validateRefreshTokenSession,
  validateRefreshTokenUnused,
  type AuthenticationSessionResolver,
  type JwkSet,
  type RefreshTokenInfo,
  type RefreshTokenResolver,
  type SigningKey,
  type TokenClientInfo,
  type TokenRequestParams,
} from '@maronn-openid-connect/core';
import {
  ACTOR_TOKEN_INVALID_DESCRIPTION,
  IdJagError,
  SUBJECT_TOKEN_INVALID_DESCRIPTION,
} from './errors.js';

/** RFC 8693 §2.1: token exchange の grant type 識別子（発行側のディスパッチ条件）。 */
export const TOKEN_EXCHANGE_GRANT_TYPE = 'urn:ietf:params:oauth:grant-type:token-exchange';

/** ID-JAG draft §4.3: 要求する token type 識別子。 */
export const ID_JAG_TOKEN_TYPE = 'urn:ietf:params:oauth:token-type:id-jag';

/** RFC 8693 §3: OIDC ID トークンの token type 識別子。subject と actor の既定種別。 */
export const TOKEN_TYPE_ID_TOKEN = 'urn:ietf:params:oauth:token-type:id_token';

/**
 * RFC 8693 §3: refresh token の token type 識別子。
 *
 * ID-JAG draft §4.3 は「実装は Identity Assertion を MUST で受け、refresh token を
 * MAY で追加受理してよい」と定める。受理すると、ID トークンの期限が切れても
 * SSO をやり直さずに新しい ID-JAG を要求できる（draft §4.3.2 / §4.4.3）。
 * 本機能では {@link IdJagIssuanceContext.refreshTokenResolver} を注入した
 * ときだけこの種別を受ける。
 */
export const TOKEN_TYPE_REFRESH_TOKEN = 'urn:ietf:params:oauth:token-type:refresh_token';

/**
 * ID-JAG draft §3.1: JOSE ヘッダーの `typ` 値。
 * RFC 8725 §3.11 の explicit typing により、ID トークンなど他種の JWT との
 * 取り違え（token confusion）を受領側が構造的に拒否できる。
 */
export const ID_JAG_JWT_TYP = 'oauth-id-jag+jwt';

/**
 * ID-JAG draft §7.2 / §8: authorization grant profile の識別子。
 * discovery の `authorization_grant_profiles_supported` に載せる値。
 */
export const ID_JAG_GRANT_PROFILE = 'urn:ietf:params:oauth:grant-profile:id-jag';

/**
 * ID-JAG の署名アルゴリズム。
 *
 * draft は alg を規定しないため、本 OP の必須アルゴリズムである RS256 に固定する
 * （JARM の応答 JWT と同じ設計）。{@link createIdJagJwt} に渡す `signingKey` は
 * RS256 鍵でなければならない。生成コードは登録鍵セットから
 * `selectSigningKeyByAlg(keys, 'RS256')` で選ぶこと。
 */
const ID_JAG_SIGNING_ALG = 'RS256';

/** RS256 に対応する Web Crypto のアルゴリズム名。 */
const WEB_CRYPTO_ALGORITHM = 'RSASSA-PKCS1-v1_5';

/**
 * RFC 8693 §4.1 の `act` claim 値。
 *
 * 発行側が actor_token（ID トークン）の組込み検証から作る値は常に 1 段
 * （`sub` のみ）。ネストした `act` は、{@link IdJagActorTokenResolver} が
 * 委譲チェーンを返したときの発行と、他の IdP が発行した ID-JAG を受領側で
 * 扱うときに現れる。
 */
export interface IdJagActor {
  sub: string;
  act?: IdJagActor;
}

/** {@link IdJagActorTokenResolver} に渡される入力。 */
export interface IdJagActorTokenResolverInput {
  /** リクエストの actor_token。構造検証（非空・対応規則）のみ済みで内容は未検証 */
  actorToken: string;
  /** リクエストの actor_token_type。id_token URN 以外の値だけがここへ来る */
  actorTokenType: string;
  /** 認証済みクライアントの client_id（actor_token の帰属確認に使える） */
  clientId: string;
}

/**
 * id_token 以外の actor_token 種別の内容検証を担うデプロイ側フック。
 *
 * RFC 8693 §2.1 の actor_token_type は任意の token type identifier を取り得る。
 * ライブラリはリクエスト構造（対応規則・非空・{@link IdJagIssuanceContext.allowActorTokens}
 * の gate）と戻り値の構造だけを検証し、トークン内容の検証（署名・失効・帰属）は
 * このリゾルバの責務とする。`urn:ietf:params:oauth:token-type:id_token` は常に
 * 組込み検証（{@link resolveIdJagActor}）で処理され、リゾルバには渡らない。
 *
 * 戻り値の契約:
 * - `IdJagActor`（`{ sub, act? }` のチェーン）— 検証済み actor。構造検証と
 *   正規化（`sub` / `act` 以外の属性の除去）を通ってから act claim になる
 * - `null` — 無効な actor_token。固定文言の invalid_request になる
 * - `IdJagError` を投げる — そのままエラー応答になる（エラー内容の細分化は
 *   オラクルになり得るため、固定文言方針の維持を推奨）
 * - その他の例外 — リゾルバの実装バグ・依存障害として伝播し、生成コードの
 *   共通 catch が server_error（500）にする
 */
export type IdJagActorTokenResolver = (
  input: IdJagActorTokenResolverInput,
) => Promise<IdJagActor | null> | IdJagActor | null;

/** 検証済みの ID-JAG 発行リクエストパラメータ（draft §4.3）。 */
export interface ParsedIdJagIssuanceParams {
  subjectToken: string;
  /** subject_token の種別。受理した URN がそのまま入る */
  subjectTokenType: typeof TOKEN_TYPE_ID_TOKEN | typeof TOKEN_TYPE_REFRESH_TOKEN;
  /** リソース AS の issuer identifier（RFC 8414 §2）。draft §4.3 で REQUIRED */
  audience: string;
  /** 空白区切りの要求 scope。省略時は undefined（scope クレームを発行しない） */
  scope?: string;
  /** RFC 8707 §2 のリソース識別子。省略時は undefined */
  resource?: string;
  /** actor のトークン。actor 受理が有効なときだけ設定され得る */
  actorToken?: string;
  /**
   * actor_token の種別。`actorToken` と常に対で設定される（RFC 8693 §2.1 の
   * 対応規則を parse が強制する）。id_token URN 以外はリゾルバ受理時のみ
   */
  actorTokenType?: string;
}

/** {@link parseIdJagIssuanceParams} の受理ポリシー。既定はどちらも無効（安全側）。 */
export interface IdJagIssuanceParseOptions {
  /**
   * refresh token の subject_token（draft §4.3 の MAY）を受けるか。
   * 生成コードは `idJagConfig.allowRefreshTokenSubjects` と resolver の有無から渡す。
   */
  allowRefreshTokenSubjects?: boolean;
  /**
   * actor_token を受けるか。draft §4.3 は actor_token の処理規則を定義しない
   * （§9.7: 将来の拡張）ため、本機能の actor 対応は draft の範囲外の拡張であり、
   * 明示的に有効化したときだけ受ける。無効時の存在は invalid_request。
   */
  allowActorTokens?: boolean;
  /**
   * id_token 以外の actor_token_type を（構造検証のうえで）通すか。
   * 生成コードは `idJagConfig.actorTokenResolver` の有無から渡す。
   * false（既定）なら id_token 以外の種別は invalid_request。
   * `allowActorTokens` が無効な間はこの値に関わらず actor_token 自体を受けない。
   */
  allowCustomActorTokenTypes?: boolean;
}

/** subject_token（ID トークン）の検証で得た発行素材。 */
export interface IdJagSubject {
  /** ID トークンの sub。ID-JAG の sub にそのまま引き継ぐ（draft §3.1） */
  sub: string;
  /** ID トークンの auth_time（存在する場合のみ。draft §3.1 OPTIONAL） */
  authTime?: number;
  /** ID トークンの acr（存在する場合のみ） */
  acr?: string;
  /** ID トークンの amr（存在する場合のみ） */
  amr?: string[];
}

/** ID-JAG のクレームセット（draft §3.1）。 */
export interface IdJagClaims {
  iss: string;
  sub: string;
  aud: string;
  client_id: string;
  jti: string;
  exp: number;
  iat: number;
  scope?: string;
  resource?: string;
  auth_time?: number;
  acr?: string;
  amr?: string[];
  /** RFC 8693 §4.1 / draft §3.1 OPTIONAL: subject の代理として振る舞う actor */
  act?: IdJagActor;
}

/** RFC 8693 §2.2.1 / draft §4.3.4 の成功レスポンスボディ。 */
export interface IdJagIssuanceResponse {
  /** ID-JAG 本体。アクセストークンではないが §2.2.1 の歴史的経緯でこの名前になる */
  access_token: string;
  issued_token_type: typeof ID_JAG_TOKEN_TYPE;
  /** 発行物がアクセストークンではないため常に N_A（draft §4.3.4 REQUIRED） */
  token_type: 'N_A';
  expires_in: number;
  scope: string;
}

/** ID-JAG 発行処理のコンテキスト。 */
export interface IdJagIssuanceContext {
  /** フォームボディのパラメータ（application/x-www-form-urlencoded） */
  params: Record<string, string>;
  /** 認証済みクライアント（分岐前の共有認証パイプラインが解決したもの） */
  client: TokenClientInfo;
  /** 自 OP（IdP）の issuer。ID-JAG の iss になり、subject_token の期待 iss にもなる */
  issuer: string;
  /** subject_token（ID トークン）の署名検証に使う自 OP の JWKS */
  jwks: JwkSet;
  /** ID-JAG の署名鍵。RS256 鍵であること */
  signingKey: SigningKey;
  /** ID-JAG を発行してよいリソース AS issuer の許可リスト。既定は空（安全側） */
  allowedAudiences: string[];
  /** 許可する scope の上限リスト。undefined は素通し（リソース AS 側ポリシーに委ねる） */
  allowedScopes?: string[];
  /** ID-JAG の有効期間（秒） */
  lifetimeSeconds: number;
  /**
   * refresh token の subject_token（draft §4.3 MAY）を受けるときに注入する。
   * 未注入なら subject_token_type=refresh_token は invalid_request で拒否される。
   * 検証は通常の refresh_token grant と同じ core のステップ関数で行う（draft §4.3.3）。
   */
  refreshTokenResolver?: RefreshTokenResolver;
  /**
   * online refresh token（ログインセッション束縛）の生存確認に使う。
   * `refreshTokenResolver` を注入するときは、通常の refresh grant と同じ resolver を
   * 渡すこと。未注入のまま online RT が提示されると fail-closed で拒否される。
   */
  authenticationSessionResolver?: AuthenticationSessionResolver;
  /**
   * actor_token（ID トークン）を受けて `act` claim を発行するか。既定 false（安全側）。
   * draft §4.3 に actor の処理規則は無く、§9.7 の指針に沿った本機能独自の拡張なので、
   * 明示的な有効化を要求する。false の間は `actorTokenResolver` を注入していても
   * actor_token を受けない（単一の親スイッチ）。
   */
  allowActorTokens?: boolean;
  /**
   * id_token 以外の actor_token_type の内容検証を担うデプロイ側フック。
   * 未注入なら id_token 以外の種別は invalid_request で拒否される。
   * id_token の組込み検証はこのフックでは差し替えられない。
   */
  actorTokenResolver?: IdJagActorTokenResolver;
  /** 現在時刻。テストと決定的な期限計算のために注入できる */
  now?: Date;
}

/**
 * 生成コードのディスパッチ用: この要求が ID-JAG 発行要求かを判定する。
 *
 * grant_type が token-exchange URN で、かつ requested_token_type が ID-JAG の
 * ときだけ真になる。既存の token-exchange 分岐より前に評価することで、両機能を
 * 同時に有効化しても要求が正しい側へ流れる。
 */
export function matchesIdJagIssuanceRequest(params: Record<string, string>): boolean {
  return (
    params['grant_type'] === TOKEN_EXCHANGE_GRANT_TYPE &&
    optional(params['requested_token_type']) === ID_JAG_TOKEN_TYPE
  );
}

/**
 * ステップ 1: クライアントが ID-JAG の発行を要求してよいかを検証する。
 *
 * draft §9.1 は本仕様を confidential client に限る SHOULD を置く。本機能は
 * これを public client の拒否まで強めている（token-exchange 機能と同じ設計判断。
 * ID-JAG はユーザー同意なしで発行されるため、クライアント認証が唯一の束縛になる）。
 *
 * @throws {IdJagError} unauthorized_client
 */
export function authorizeIdJagIssuanceClient(client: TokenClientInfo): void {
  // OIDC Dynamic Client Registration 1.0 §2 / RFC 7591 §2: grantTypes 未指定は
  // ['authorization_code'] 扱い。よって発行は token-exchange URN を明示登録した
  // クライアントのみ許される。
  const grantTypes = client.grantTypes ?? ['authorization_code'];
  if (!grantTypes.includes(TOKEN_EXCHANGE_GRANT_TYPE)) {
    throw new IdJagError(
      'unauthorized_client',
      'The client is not authorized to use the token-exchange grant type',
    );
  }
  if (client.tokenEndpointAuthMethod === 'none') {
    throw new IdJagError(
      'unauthorized_client',
      'Public clients are not allowed to request an ID-JAG',
    );
  }
}

/**
 * ステップ 2: 必須・非対応パラメータを検証して型付けする（draft §4.3）。
 *
 * 空文字・空白のみの任意パラメータは「送られなかった」と同じに扱う
 * （token-exchange 機能と同じ規則）。受理する subject 種別と actor の可否は
 * {@link IdJagIssuanceParseOptions} で決まり、既定はどちらも無効
 * （ID トークンの subject だけを受ける従来どおりの形）。
 *
 * @throws {IdJagError} invalid_request
 */
export function parseIdJagIssuanceParams(
  params: Record<string, string>,
  options: IdJagIssuanceParseOptions = {},
): ParsedIdJagIssuanceParams {
  const subjectToken = optional(params['subject_token']);
  if (subjectToken === undefined) {
    throw new IdJagError('invalid_request', 'subject_token is required');
  }

  const subjectTokenType = optional(params['subject_token_type']);
  if (subjectTokenType === undefined) {
    throw new IdJagError('invalid_request', 'subject_token_type is required');
  }
  // draft §4.3: Identity Assertion（本機能では ID トークン）は MUST、refresh token は
  // MAY。saml2 は本 OP が SAML を発行しないため受けない（仕様の非目標）。
  const supportedSubjectTypes: string[] = [
    TOKEN_TYPE_ID_TOKEN,
    ...(options.allowRefreshTokenSubjects === true ? [TOKEN_TYPE_REFRESH_TOKEN] : []),
  ];
  if (!supportedSubjectTypes.includes(subjectTokenType)) {
    throw new IdJagError(
      'invalid_request',
      `Unsupported subject_token_type for ID-JAG issuance. Only ${supportedSubjectTypes.join(' or ')} is supported.`,
    );
  }

  // draft §4.3: audience は REQUIRED（RFC 8693 では OPTIONAL だが、この profile が
  // 必須へ強めている）。ID-JAG の aud クレームそのものになる。
  const audience = optional(params['audience']);
  if (audience === undefined) {
    throw new IdJagError('invalid_request', 'audience is required');
  }

  const resource = optional(params['resource']);
  if (resource !== undefined && !isAbsoluteUriWithoutFragment(resource)) {
    // RFC 8707 §2: resource は絶対 URI で fragment を含んではならない（query は許容）。
    throw new IdJagError(
      'invalid_request',
      'resource must be an absolute URI without a fragment component',
    );
  }

  const actorToken = optional(params['actor_token']);
  const actorTokenType = optional(params['actor_token_type']);
  if (options.allowActorTokens !== true) {
    // draft §4.3 は actor_token を運べることだけを定め、処理規則を定義しない
    // （§9.7: 将来の拡張）。規則を有効化していない構成で受け取ると委譲の権限が
    // 過大表明され得るため、明示的に拒否する（fail-safe）。
    if (actorToken !== undefined || actorTokenType !== undefined) {
      throw new IdJagError(
        'invalid_request',
        'actor_token is not supported for ID-JAG issuance',
      );
    }
  } else {
    // RFC 8693 §2.1: actor_token_type は actor_token があるとき REQUIRED、
    // 無いとき MUST NOT be included。
    if (actorToken !== undefined && actorTokenType === undefined) {
      throw new IdJagError(
        'invalid_request',
        'actor_token_type is required when actor_token is present',
      );
    }
    if (actorToken === undefined && actorTokenType !== undefined) {
      throw new IdJagError(
        'invalid_request',
        'actor_token_type must not be present without actor_token',
      );
    }
    // actor は「誰が subject の代理として振る舞うか」の本人表明なので、既定では
    // subject と同じく本 OP 発行の ID トークンに限る。他の種別（RFC 8693 §2.1 は
    // 任意の token type identifier を許す）は、内容検証を担うリゾルバが注入
    // されているときだけ通す。ここでの検証はリクエスト構造まで（内容はリゾルバ）。
    if (
      actorTokenType !== undefined &&
      actorTokenType !== TOKEN_TYPE_ID_TOKEN &&
      options.allowCustomActorTokenTypes !== true
    ) {
      throw new IdJagError(
        'invalid_request',
        `Unsupported actor_token_type for ID-JAG issuance. Only ${TOKEN_TYPE_ID_TOKEN} is supported.`,
      );
    }
  }

  // RAR（RFC 9396）は非対応（仕様の非目標）。無視して発行すると要求より狭い
  // 権限表明と誤解されるため、明示的に拒否する。
  if (optional(params['authorization_details']) !== undefined) {
    throw new IdJagError(
      'invalid_request',
      'authorization_details is not supported for ID-JAG issuance',
    );
  }

  return {
    subjectToken,
    subjectTokenType: subjectTokenType as ParsedIdJagIssuanceParams['subjectTokenType'],
    audience,
    scope: optional(params['scope']),
    resource,
    // 対応規則の検証済み: actorToken があれば actorTokenType も必ずある。
    ...(actorToken === undefined
      ? {}
      : { actorToken, actorTokenType: actorTokenType as string }),
  };
}

/**
 * ステップ 3: subject_token（ID トークン）を検証し、発行素材を返す。
 *
 * draft §4.3.3: IdP は assertion を検証し、その audience（ID トークンの aud）が
 * リクエストのクライアント認証の client_id と一致することを検証しなければ
 * ならない（MUST）。他クライアント宛てに発行された ID トークンの持ち込みを防ぐ。
 *
 * 検証本体は core の `validateIdTokenHint` に委譲する。署名（事前登録 JWKS のみ・
 * kid / alg による鍵選択）、iss、aud、exp / iat（leeway 60 秒）、`alg: none` と
 * 外部鍵取得ヘッダ（jku / jwk / x5u / x5c）の拒否がそのまま適用される。
 *
 * 失敗理由は応答から区別できない（{@link SUBJECT_TOKEN_INVALID_DESCRIPTION}）。
 *
 * @throws {IdJagError} invalid_request（固定文言）
 */
export async function resolveIdJagSubject(options: {
  subjectToken: string;
  issuer: string;
  clientId: string;
  jwks: JwkSet;
}): Promise<IdJagSubject> {
  let payload: { sub: string; [key: string]: unknown };
  try {
    payload = await validateIdTokenHint(options.subjectToken, {
      expectedIss: options.issuer,
      expectedAud: options.clientId,
      jwks: options.jwks,
    });
  } catch (error) {
    if (error instanceof IdTokenHintError) {
      throw new IdJagError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION);
    }
    throw error;
  }

  // auth_time / acr / amr は ID トークンに存在する場合だけ ID-JAG へ引き継ぐ
  // （draft §3.1 OPTIONAL。リソース AS 側の認証コンテキスト評価の材料）。
  const authTime = typeof payload['auth_time'] === 'number' ? payload['auth_time'] : undefined;
  const acr = typeof payload['acr'] === 'string' ? payload['acr'] : undefined;
  const amr =
    Array.isArray(payload['amr']) && payload['amr'].every((v) => typeof v === 'string')
      ? (payload['amr'] as string[])
      : undefined;

  return {
    sub: payload.sub,
    ...(authTime === undefined ? {} : { authTime }),
    ...(acr === undefined ? {} : { acr }),
    ...(amr === undefined ? {} : { amr }),
  };
}

/**
 * ステップ 3-R: refresh token の subject_token を検証し、発行素材を返す（draft §4.3.2）。
 *
 * draft §4.3.3: 「subject token が refresh token の場合、IdP は通常の refresh_token
 * grant と同じ方法で検証しなければならない（発行元が自 OP、認証クライアントへの
 * 束縛、未失効、未 rotation）」。これを core の refresh grant ステップ関数の再利用で
 * 満たす。したがって rotation 済み RT の再提示は、refresh grant と同じく token family
 * の失効（`revokeTokensByGrantId`）を発火させたうえで拒否される。
 *
 * RT 自体は消費しない（rotation しない）。この交換は refresh grant ではなく、
 * クライアントは同じ RT で ID-JAG を繰り返し要求できる（draft §4.4.3 の想定）。
 *
 * subject のクレームは RT の保存情報（subject / authTime / acr / amr）から組み立てる。
 * draft §4.3.3 SHOULD の「新しい Identity Assertion を発行するときと同じように
 * subject のクレームを取得する」に相当し、ID トークン経路と同じ材料が得られる。
 * ただし `openid` scope を持たない grant の RT は拒否する。ID トークン（Identity
 * Assertion）が存在し得ない grant の RT は、その代替という位置づけを満たさないためだ。
 *
 * 失敗理由は応答から区別できない（{@link SUBJECT_TOKEN_INVALID_DESCRIPTION}）。
 *
 * @throws {IdJagError} invalid_request（固定文言）
 */
export async function resolveIdJagSubjectFromRefreshToken(options: {
  refreshToken: string;
  clientId: string;
  refreshTokenResolver: RefreshTokenResolver;
  authenticationSessionResolver?: AuthenticationSessionResolver;
  now?: Date;
}): Promise<IdJagSubject> {
  let info: RefreshTokenInfo;
  try {
    const resolved = await resolveRefreshToken(
      {
        grant_type: 'refresh_token',
        refresh_token: options.refreshToken,
      } as TokenRequestParams,
      options.refreshTokenResolver,
    );
    info = resolved.refreshTokenInfo;

    // OAuth 2.1 §4.3.1: rotation 済み RT の再提示は盗難シグナル。refresh grant と
    // 同じく family 失効を発火させてから拒否する。
    await validateRefreshTokenUnused(info, options.refreshTokenResolver);
    validateRefreshTokenClient(info, options.clientId);
    validateRefreshTokenExpiration(
      info,
      Math.floor((options.now ?? new Date()).getTime() / 1000),
    );
    // online refresh token はログインセッションの生存中だけ有効（refresh grant と
    // 同じ判定）。resolver 未注入のまま online RT が来た場合は fail-closed で throw。
    await validateRefreshTokenSession(info, options.authenticationSessionResolver);
  } catch (error) {
    if (error instanceof TokenError) {
      throw invalidSubjectToken();
    }
    throw error;
  }

  if (!info.scope.includes('openid')) {
    throw invalidSubjectToken();
  }

  return {
    sub: info.subject,
    authTime: info.authTime,
    ...(info.acr === undefined ? {} : { acr: info.acr }),
    ...(info.amr === undefined ? {} : { amr: info.amr }),
  };
}

/**
 * ステップ 3': actor_token（ID トークン）を検証し、`act` claim の値を返す。
 *
 * draft §4.3 は actor_token の処理規則を定義せず、§9.7 が拡張の指針を示すだけ
 * なので、これは本機能独自の拡張である。§9.7 の指針に沿って次を固定する:
 *
 * - actor_token は subject と同じく**本 OP 発行の ID トークン**で、`aud` が
 *   認証済みクライアントと一致すること（無関係な、あるいはより信頼の低い
 *   トークンの持ち込みで actor の権威を過大表明させない）
 * - `act` に載せるのは actor の `sub` だけ（不要な属性を別ドメインへ流さない）
 * - `sub`（resource owner）と `act`（actor）の区別は claim 構造がそのまま保つ
 *
 * 検証は {@link resolveIdJagSubject} と同じく core の `validateIdTokenHint` に
 * 委譲する。失敗理由は応答から区別できない
 * （{@link ACTOR_TOKEN_INVALID_DESCRIPTION}）。
 *
 * @throws {IdJagError} invalid_request（固定文言）
 */
export async function resolveIdJagActor(options: {
  actorToken: string;
  issuer: string;
  clientId: string;
  jwks: JwkSet;
}): Promise<IdJagActor> {
  let payload: { sub: string; [key: string]: unknown };
  try {
    payload = await validateIdTokenHint(options.actorToken, {
      expectedIss: options.issuer,
      expectedAud: options.clientId,
      jwks: options.jwks,
    });
  } catch (error) {
    if (error instanceof IdTokenHintError) {
      throw new IdJagError('invalid_request', ACTOR_TOKEN_INVALID_DESCRIPTION);
    }
    throw error;
  }
  return { sub: payload.sub };
}

/**
 * ステップ 3'-C: id_token 以外の actor_token をデプロイ側リゾルバへ委譲する。
 *
 * ライブラリ側の検証は「リクエスト構造」（parse 済み）と「リゾルバ戻り値の構造」
 * まで。トークン内容の検証（署名・失効・帰属）は {@link IdJagActorTokenResolver}
 * の契約どおりリゾルバの責務とする。戻り値は正規化コピーを経由し、`sub` / `act`
 * 以外の属性は act claim に載せない（draft §9.7 の開示最小化）。ネストした
 * `act` チェーンはそのまま発行できる（actor_token 自体が委譲済みのケース）。
 *
 * id_token 種別はこの関数を通らない（{@link resolveIdJagActor} の組込み検証が
 * 常に適用され、リゾルバでは差し替えられない）。
 *
 * @throws {IdJagError} invalid_request（リゾルバが null を返した。固定文言）、
 *   またはリゾルバ自身が投げた IdJagError（そのまま透過する）
 * @throws {Error} リゾルバが malformed な actor を返した（デプロイ側のバグ。
 *   生成コードの共通 catch が server_error にする）
 */
export async function resolveIdJagActorFromCustomToken(options: {
  actorToken: string;
  actorTokenType: string;
  clientId: string;
  resolver: IdJagActorTokenResolver;
}): Promise<IdJagActor> {
  const resolved = await options.resolver({
    actorToken: options.actorToken,
    actorTokenType: options.actorTokenType,
    clientId: options.clientId,
  });
  if (resolved === null) {
    throw new IdJagError('invalid_request', ACTOR_TOKEN_INVALID_DESCRIPTION);
  }
  const actor = copyActorChain(resolved);
  if (actor === undefined) {
    throw new Error(
      'The actorTokenResolver returned a malformed actor: sub must be a non-empty string at every level of the act chain',
    );
  }
  return actor;
}

/**
 * リゾルバ戻り値の構造検証を兼ねた正規化コピー。
 * `sub`（非空文字列）と同形のネスト `act` だけを写し、他の属性は落とす。
 * 構造が壊れていれば undefined。
 */
function copyActorChain(value: unknown): IdJagActor | undefined {
  if (typeof value !== 'object' || value === null) {
    return undefined;
  }
  const record = value as Record<string, unknown>;
  const sub = record['sub'];
  if (typeof sub !== 'string' || sub.length === 0) {
    return undefined;
  }
  if (record['act'] === undefined) {
    return { sub };
  }
  const act = copyActorChain(record['act']);
  return act === undefined ? undefined : { sub, act };
}

/**
 * ステップ 4: audience を検証する。
 *
 * - draft §9.3: IdP は自分が発行した ID-JAG に対して同一ドメイン内でアクセス
 *   トークンを発行してはならない。自 OP の issuer と同一の audience 要求は、
 *   その禁止された構成そのものなので発行時点で拒否する（受領側の iss 検証と
 *   合わせた二重ガード）。
 * - 許可リスト（既定は空）に無い audience は拒否する。error_description は
 *   リストの内容・部分一致情報を露出しない固定文言。
 *
 * issuer identifier の比較は byte-exact（RFC 8414 §2 の識別子比較）。
 *
 * @throws {IdJagError} invalid_target
 */
export function validateIdJagAudience(options: {
  audience: string;
  issuer: string;
  allowedAudiences: string[];
}): void {
  if (options.audience === options.issuer) {
    // 利用者が自力で直せる構成エラーなので、この場合だけ理由を明示する
    // （自 OP の issuer は公開情報でありオラクルにならない）。
    throw new IdJagError(
      'invalid_target',
      'The requested audience must belong to a different trust domain than this authorization server',
    );
  }
  if (!options.allowedAudiences.includes(options.audience)) {
    throw new IdJagError(
      'invalid_target',
      'The requested audience is not allowed for ID-JAG issuance',
    );
  }
}

/**
 * ステップ 5: 要求 scope を検証し、ID-JAG に載せる実効 scope を返す。
 *
 * draft §4.3.3: IdP はポリシーを評価し、許可 scope は要求の部分集合であってよい。
 * 本機能のポリシーは「`allowedScopes` が設定されていればその部分集合のみ許可、
 * 未設定なら要求をそのまま許可」。未設定素通しにするのは、scope の意味論が
 * リソース AS のドメインに属し、受領側でも同じ縮小ポリシーが働くため
 * （設計判断。仕様書の設定値の節を参照）。
 *
 * @throws {IdJagError} invalid_scope
 */
export function validateIdJagScope(
  requestedScope: string | undefined,
  allowedScopes: string[] | undefined,
): string[] {
  const requested = splitScope(requestedScope);
  if (allowedScopes === undefined) {
    return requested;
  }
  for (const value of requested) {
    if (!allowedScopes.includes(value)) {
      throw new IdJagError(
        'invalid_scope',
        'The requested scope exceeds the scopes allowed for ID-JAG issuance',
      );
    }
  }
  return requested;
}

/**
 * ステップ 6: ID-JAG のクレームセットを組み立てる（draft §3.1）。
 *
 * - `client_id` は交換を要求した認証済みクライアントの client_id。draft §5 は
 *   リソース AS 側で別の client_id を使う対応付けも認めるが、本機能は両 AS で
 *   同一 client_id を使う前提に固定する（仕様の非目標）。
 * - `scope` は空配列のときクレーム自体を含めない（draft §3.1 OPTIONAL）。
 * - `jti` は 256bit のランダム値。受領側はリプレイ拒否には使わないが（draft
 *   §4.4.3 の再提示を許すため）、grant 単位の追跡とログ相関に使える。
 *
 * @throws {RangeError} lifetimeSeconds が正の整数でない場合（設定ミス）
 */
export function buildIdJagClaims(options: {
  issuer: string;
  subject: IdJagSubject;
  audience: string;
  clientId: string;
  scope: string[];
  resource?: string;
  /** actor 受理時のみ（{@link resolveIdJagActor} の戻り値）。act claim になる */
  actor?: IdJagActor;
  lifetimeSeconds: number;
  now?: Date;
}): IdJagClaims {
  if (!Number.isInteger(options.lifetimeSeconds) || options.lifetimeSeconds <= 0) {
    throw new RangeError(
      `lifetimeSeconds must be a positive integer, received ${options.lifetimeSeconds}`,
    );
  }
  const issuedAt = Math.floor((options.now ?? new Date()).getTime() / 1000);
  return {
    iss: options.issuer,
    sub: options.subject.sub,
    aud: options.audience,
    client_id: options.clientId,
    jti: generateRandomString(32),
    exp: issuedAt + options.lifetimeSeconds,
    iat: issuedAt,
    ...(options.scope.length === 0 ? {} : { scope: options.scope.join(' ') }),
    ...(options.resource === undefined ? {} : { resource: options.resource }),
    ...(options.subject.authTime === undefined ? {} : { auth_time: options.subject.authTime }),
    ...(options.subject.acr === undefined ? {} : { acr: options.subject.acr }),
    ...(options.subject.amr === undefined ? {} : { amr: options.subject.amr }),
    ...(options.actor === undefined ? {} : { act: options.actor }),
  };
}

/**
 * ステップ 7: ID-JAG を compact JWS として署名する。
 *
 * JOSE ヘッダーは `{ alg: 'RS256', typ: 'oauth-id-jag+jwt', kid }`。
 * `typ` は受領側の必須検証項目（draft §4.4.1 / RFC 8725 §3.11）なので必ず付ける。
 * `kid` を含めるのは、受領側が IdP の JWKS から鍵を一意に選べるようにするため。
 *
 * @param options.signingKey RS256 鍵であること（alg 表明と鍵種の不一致は Web
 *   Crypto が署名時に例外にするため、偽った alg の JWS は生成されない）
 */
export async function createIdJagJwt(options: {
  claims: IdJagClaims;
  signingKey: SigningKey;
}): Promise<string> {
  const encodedHeader = base64UrlFromJson({
    alg: ID_JAG_SIGNING_ALG,
    typ: ID_JAG_JWT_TYP,
    kid: options.signingKey.keyId,
  });
  const encodedPayload = base64UrlFromJson(options.claims as unknown as Record<string, unknown>);
  const signingInput = `${encodedHeader}.${encodedPayload}`;

  const signature = await crypto.subtle.sign(
    WEB_CRYPTO_ALGORITHM,
    options.signingKey.privateKey,
    new TextEncoder().encode(signingInput),
  );

  return `${signingInput}.${base64UrlFromBytes(new Uint8Array(signature))}`;
}

/**
 * ステップ 8: RFC 8693 §2.2.1 / draft §4.3.4 の応答ボディを組み立てる。
 *
 * `token_type` は常に `N_A`（発行物はアクセストークンではない）。`scope` は
 * draft 上「要求と同一なら OPTIONAL」だが、判定分岐を避けるため常に含める
 * （token-exchange 機能と同じ設計判断。scope 無しの発行では空文字列）。
 * refresh_token は返さない（draft §4.3.4 SHOULD NOT）。
 */
export function buildIdJagIssuanceResponse(options: {
  idJag: string;
  expiresIn: number;
  scope: string[];
}): IdJagIssuanceResponse {
  return {
    access_token: options.idJag,
    issued_token_type: ID_JAG_TOKEN_TYPE,
    token_type: 'N_A',
    expires_in: options.expiresIn,
    scope: options.scope.join(' '),
  };
}

/**
 * 合成関数: ID-JAG 発行の検証〜応答生成（draft §4.3）。
 *
 * 個々のステップ関数を仕様順に合成しただけの API。ID-JAG はストアに保存しない
 * （自己完結した署名付き grant であり、受領側が署名と exp で検証する）。
 *
 * @throws {IdJagError}
 */
export async function processIdJagIssuanceRequest(
  context: IdJagIssuanceContext,
): Promise<IdJagIssuanceResponse> {
  // クライアント認可を最初に行う。許可されていないクライアントには
  // subject_token の有効性すら判定させない（オラクルを与えない）。
  authorizeIdJagIssuanceClient(context.client);

  const parsed = parseIdJagIssuanceParams(context.params, {
    allowRefreshTokenSubjects: context.refreshTokenResolver !== undefined,
    allowActorTokens: context.allowActorTokens === true,
    allowCustomActorTokenTypes: context.actorTokenResolver !== undefined,
  });

  const subject =
    parsed.subjectTokenType === TOKEN_TYPE_REFRESH_TOKEN
      ? await resolveIdJagSubjectFromRefreshToken({
          refreshToken: parsed.subjectToken,
          clientId: context.client.clientId,
          // parse が refresh subject を受けた時点で resolver は注入済み。
          refreshTokenResolver: context.refreshTokenResolver as RefreshTokenResolver,
          ...(context.authenticationSessionResolver === undefined
            ? {}
            : { authenticationSessionResolver: context.authenticationSessionResolver }),
          ...(context.now === undefined ? {} : { now: context.now }),
        })
      : await resolveIdJagSubject({
          subjectToken: parsed.subjectToken,
          issuer: context.issuer,
          clientId: context.client.clientId,
          jwks: context.jwks,
        });

  // actor（拡張）: subject の解決後に検証する。act は「誰が subject の代理として
  // 振る舞うか」の記録であり、sub は actor が居ても変わらない（RFC 8693 §4.1）。
  // id_token 種別は常に組込み検証で、リゾルバでは差し替えられない。それ以外の
  // 種別は parse がリゾルバ注入時にだけ通しているので、ここでは非 undefined を
  // 前提にできる。
  const actor =
    parsed.actorToken === undefined
      ? undefined
      : parsed.actorTokenType === TOKEN_TYPE_ID_TOKEN
        ? await resolveIdJagActor({
            actorToken: parsed.actorToken,
            issuer: context.issuer,
            clientId: context.client.clientId,
            jwks: context.jwks,
          })
        : await resolveIdJagActorFromCustomToken({
            actorToken: parsed.actorToken,
            // 対応規則の検証済み: actorToken があれば actorTokenType もある。
            actorTokenType: parsed.actorTokenType as string,
            clientId: context.client.clientId,
            // parse が独自種別を受けた時点で resolver は注入済み。
            resolver: context.actorTokenResolver as IdJagActorTokenResolver,
          });

  validateIdJagAudience({
    audience: parsed.audience,
    issuer: context.issuer,
    allowedAudiences: context.allowedAudiences,
  });

  const scope = validateIdJagScope(parsed.scope, context.allowedScopes);

  const claims = buildIdJagClaims({
    issuer: context.issuer,
    subject,
    audience: parsed.audience,
    clientId: context.client.clientId,
    scope,
    ...(parsed.resource === undefined ? {} : { resource: parsed.resource }),
    ...(actor === undefined ? {} : { actor }),
    lifetimeSeconds: context.lifetimeSeconds,
    ...(context.now === undefined ? {} : { now: context.now }),
  });

  const idJag = await createIdJagJwt({
    claims,
    signingKey: context.signingKey,
  });

  return buildIdJagIssuanceResponse({
    idJag,
    expiresIn: context.lifetimeSeconds,
    scope,
  });
}

/** 空文字・空白のみを「未指定」として扱う。 */
function optional(value: string | undefined): string | undefined {
  if (value === undefined) return undefined;
  const trimmed = value.trim();
  return trimmed.length === 0 ? undefined : trimmed;
}

function invalidSubjectToken(): IdJagError {
  return new IdJagError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION);
}

function splitScope(scope: string | undefined): string[] {
  if (scope === undefined) return [];
  return [...new Set(scope.split(/\s+/).filter((value) => value.length > 0))];
}

/**
 * RFC 8707 §2: resource は絶対 URI（RFC 3986 §4.3）で fragment を含んではならない。
 * query は許容される。
 */
function isAbsoluteUriWithoutFragment(value: string): boolean {
  if (value.includes('#')) return false;
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return false;
  }
  return parsed.protocol.length > 0;
}

function base64UrlFromBytes(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function base64UrlFromJson(value: Record<string, unknown>): string {
  return base64UrlFromBytes(new TextEncoder().encode(JSON.stringify(value)));
}
```

### redeem-id-jag.ts（受領側: リソース AS の役割）

受領側の中心は `verifyIdJagAssertion` で、RFC 7521 §5.2 の一般規則に draft §4.4.1 の処理規則を重ねた 11 項目を順に検証する。
`aud` は自 issuer との完全一致で、配列は要素数 1 だけを許す（draft の MUST。audience injection の拒否）。
`client_id` クレームと認証クライアントの一致（クライアント継続性）が、盗まれた ID-JAG を別クライアントが換金する経路を塞ぐ。
実効 scope の導出（`resolveIdJagGrantScope`）では `offline_access` を常に除去する。jwt-bearer では refresh token を発行しない（draft §4.4.3 SHOULD NOT）ので、実効 scope に残すと同意していない長期アクセスの表明になるからだ。
`act` クレームは構造検証（`sub` 必須、ネストは同形）のうえで grant 素材へ引き継ぎ、生成コードが発行するアクセストークンに記録させる。

```typescript
/**
 * Identity Assertion Authorization Grant (ID-JAG) の受領 — リソース AS 側
 * draft-ietf-oauth-identity-assertion-authz-grant-04 §4.4 / RFC 7523 §2.1・§3 / RFC 7521 §5.2
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * トークンエンドポイントの `urn:ietf:params:oauth:grant-type:jwt-bearer` grant を
 * 処理する。信頼設定済みの外部 IdP が署名した ID-JAG（`typ: oauth-id-jag+jwt`）
 * だけを assertion として受け、検証のうえアクセストークンの発行素材を導出する。
 * 素の RFC 7523 assertion（他の typ）は受けない（仕様の非目標）。
 *
 * トークンの発行・保存は行わない。呼び出し側（生成コード）が core の
 * `buildAccessTokenAudience` / `buildAccessTokenPayload` / `AccessTokenIssuer` /
 * `accessTokenStore` と組み合わせる（token-exchange 機能と同じ分担）。
 *
 * JWS の検証は Web Crypto API による自前実装で、鍵は必ず注入された信頼 IdP の
 * JWKS から選ぶ。assertion の内容（jku ヘッダなど）から鍵の取得先を導出する
 * 経路は存在しない（RFC 8725 §3.1 / SSRF 対策）。ネットワーク取得（jwks_uri）は
 * 本モジュールの責務ではなく、生成コード側で解決してから渡す。
 */
import type { webcrypto } from 'node:crypto';
import {
  extractAlgorithmParamsFromJwk,
  type AccessTokenInfo,
  type Jwk,
  type JwkSet,
  type TokenClientInfo,
} from '@maronn-openid-connect/core';
import {
  ASSERTION_UNTRUSTED_DESCRIPTION,
  IdJagError,
} from './errors.js';
import { ID_JAG_JWT_TYP, type IdJagActor } from './issue-id-jag.js';

/** RFC 7523 §2.1: JWT authorization grant の grant type 識別子。 */
export const JWT_BEARER_GRANT_TYPE = 'urn:ietf:params:oauth:grant-type:jwt-bearer';

/**
 * Clock skew 許容の既定値（秒）。
 * RFC 8725 §3.8: leeway は数分以内に留める。core の ID トークン検証と同じ 60 秒。
 */
export const DEFAULT_ASSERTION_CLOCK_SKEW_SEC = 60;

/**
 * 信頼する IdP の解決済みエントリ。
 *
 * `jwks` は検証時点で手元にある JWK セット（インライン設定、または生成コードが
 * jwks_uri から取得してキャッシュしたもの）。issuer は RFC 8414 §2 の issuer
 * identifier で、assertion の `iss` と byte-exact に比較される。
 */
export interface IdJagTrustedIdentityProvider {
  issuer: string;
  jwks: JwkSet;
}

/** 検証済みの jwt-bearer リクエストパラメータ。 */
export interface ParsedIdJagRedemptionParams {
  assertion: string;
  /** 空白区切りの要求 scope。省略時は undefined（ID-JAG の scope を継承する） */
  scope?: string;
}

/** 検証を通過した ID-JAG のペイロード（draft §3.1）。 */
export interface IdJagAssertionPayload {
  iss: string;
  sub: string;
  aud: string | string[];
  client_id: string;
  jti: string;
  exp: number;
  iat: number;
  scope?: string;
  /** RFC 8707 のリソース識別子。単一 URI または URI 配列（draft §3.1） */
  resource?: string | string[];
  auth_time?: number;
  acr?: string;
  amr?: string[];
  /** RFC 8693 §4.1 / draft §3.1 OPTIONAL: subject の代理として振る舞う actor */
  act?: IdJagActor;
}

/**
 * 発行素材。生成コードはこれを core の `buildAccessTokenAudience` /
 * `buildAccessTokenPayload` / `AccessTokenIssuer.issue` / `accessTokenStore.set` へ流す。
 */
export interface IdJagRedemptionGrant {
  /** ID-JAG の sub をそのままローカル subject として使う（JIT 対応は非目標） */
  subject: string;
  /** redemption を要求した認証済みクライアント（= ID-JAG の client_id） */
  clientId: string;
  /** 実効 scope（ID-JAG の scope から offline_access を除去し、要求で縮小した値） */
  scope: string[];
  /** ID-JAG の resource クレーム。core の `buildAccessTokenAudience` の `requested` へ渡す */
  requestedResources?: string[];
  /**
   * 発行するアクセストークンの有効期間（秒）。設定値をそのまま使い、ID-JAG の
   * 残存期間で cap しない（draft §4.4.3: アクセストークン失効後は同じ ID-JAG を
   * 再提示して再取得する設計で、grant はトークンより短命でよい）。
   */
  expiresIn: number;
  /** ID-JAG を発行した IdP の issuer（監査ログとストアメタデータ用） */
  idpIssuer: string;
  /** ID-JAG の jti（ログ相関用。リプレイ拒否には使わない） */
  jti: string;
  authTime?: number;
  acr?: string;
  amr?: string[];
  /**
   * ID-JAG の act claim。存在する場合、生成コードは発行するアクセストークンの
   * payload と store メタデータの両方へ `act` として引き継ぐ（RFC 8693 §4.1 の
   * 意味論を下流に保つ。黙って落とすと actor の記録が消え、委譲が impersonation に
   * 化ける — draft §9.7 が警告する方向の劣化）。
   */
  actor?: IdJagActor;
}

/**
 * redemption で発行したアクセストークンの store metadata。
 *
 * core の {@link AccessTokenInfo} に `act` を加えた構造的拡張。act 付き ID-JAG から
 * 発行したトークンをこの形で保存すると、introspection や後続処理が actor の記録を
 * 参照できる（core は無変更のまま。token-exchange 機能の同名パターンと同型）。
 */
export type IdJagAccessTokenInfo = AccessTokenInfo & {
  act?: IdJagActor;
};

/** ID-JAG redemption 処理のコンテキスト。 */
export interface IdJagRedemptionContext {
  /** フォームボディのパラメータ（application/x-www-form-urlencoded） */
  params: Record<string, string>;
  /** 認証済みクライアント（分岐前の共有認証パイプラインが解決したもの） */
  client: TokenClientInfo;
  /** 自 OP（リソース AS）の issuer。assertion の期待 aud であり、自己発行拒否の基準 */
  issuer: string;
  /** 信頼する IdP のリスト（JWKS 解決済み）。既定は空（安全側） */
  identityProviders: IdJagTrustedIdentityProvider[];
  /** 設定上のアクセストークン有効期間（秒） */
  configuredExpiresIn: number;
  /** 現在時刻。テストと決定的な期限計算のために注入できる */
  now?: Date;
  /** exp / iat / nbf 判定の leeway（秒）。既定 60 */
  clockSkewToleranceSec?: number;
}

/**
 * RFC 7515 が「鍵を外部から取得するための情報源」として定義する JOSE Header
 * フィールド。鍵は事前登録済みの信頼 IdP の JWKS からだけ選ぶため、受信 JWS に
 * 含まれていたら即拒否する（RFC 8725 §3.1: SSRF と任意公開鍵差し替えの防止）。
 */
const FORBIDDEN_KEY_HEADERS = ['jku', 'x5u', 'jwk', 'x5c'] as const;

/**
 * ステップ 1: クライアントが jwt-bearer grant を使ってよいかを検証する。
 *
 * RFC 7521 §4.1 は authorization grant の assertion でクライアント認証を必須と
 * しないが、draft §4.4.1 は ID-JAG の client_id クレームと「リクエストの認証
 * クライアント」の一致を MUST とし、§9.1 は confidential client 限定の SHOULD を
 * 置く。本機能はこれを public client の拒否まで強めている（発行側と同じ設計判断）。
 *
 * @throws {IdJagError} unauthorized_client
 */
export function authorizeIdJagRedemptionClient(client: TokenClientInfo): void {
  // RFC 7591 §2: grantTypes 未指定は ['authorization_code'] 扱い。よって redemption は
  // jwt-bearer URN を明示登録したクライアントのみ許される。
  const grantTypes = client.grantTypes ?? ['authorization_code'];
  if (!grantTypes.includes(JWT_BEARER_GRANT_TYPE)) {
    throw new IdJagError(
      'unauthorized_client',
      'The client is not authorized to use the jwt-bearer grant type',
    );
  }
  if (client.tokenEndpointAuthMethod === 'none') {
    throw new IdJagError(
      'unauthorized_client',
      'Public clients are not allowed to use the jwt-bearer grant type',
    );
  }
}

/**
 * ステップ 2: 必須・非対応パラメータを検証して型付けする（RFC 7523 §2.1）。
 *
 * @throws {IdJagError} invalid_request
 */
export function parseIdJagRedemptionParams(
  params: Record<string, string>,
): ParsedIdJagRedemptionParams {
  const assertion = optional(params['assertion']);
  if (assertion === undefined) {
    throw new IdJagError('invalid_request', 'assertion is required');
  }

  // RAR（RFC 9396）は非対応（仕様の非目標）。発行側と同じく明示的に拒否する。
  if (optional(params['authorization_details']) !== undefined) {
    throw new IdJagError(
      'invalid_request',
      'authorization_details is not supported for the jwt-bearer grant',
    );
  }

  return {
    assertion,
    scope: optional(params['scope']),
  };
}

/**
 * ステップ 3: assertion（ID-JAG）を検証し、ペイロードを返す。
 *
 * RFC 7521 §5.2 の一般規則に加え、draft §4.4.1 の処理規則を適用する:
 *
 * 1. compact JWS として構造が正しいこと
 * 2. `typ` が `oauth-id-jag+jwt` であること（RFC 8725 §3.11 の explicit typing。
 *    RFC 7515 §4.1.9 に従い `application/` 前置と大文字小文字の差は許容する）
 * 3. `alg` があり `none` でないこと。外部鍵取得ヘッダが無いこと
 * 4. `iss` が信頼 IdP のいずれかと一致し、かつ自 OP の issuer と異なること
 *    （draft §9.3: 同一ドメイン内で ID-JAG をアクセストークンに引き換えない）
 * 5. 署名がその IdP の JWKS で検証できること（kid 一致を優先、無ければ alg 一致
 *    鍵を順次試行。鍵ごとの alg ピン留めは core の ID トークン検証と同じ規則）
 * 6. `aud` が自 OP の issuer と一致すること。文字列、または要素数 1 の配列のみ
 *    許す（draft §4.4.1 MUST。要素数 2 以上は audience injection として拒否）
 * 7. `exp` / `iat` / `nbf`（存在時）が leeway 内で妥当なこと
 * 8. `jti` / `sub` が非空文字列であること
 * 9. `client_id` が認証済みクライアントと一致すること（draft §4.4.1 MUST。
 *    盗まれた ID-JAG を別クライアントが換金する経路を塞ぐ）
 *
 * `iss` 非信頼と署名不正は同一の固定文言で返し、信頼 IdP リストを応答から
 * 探索させない（{@link ASSERTION_UNTRUSTED_DESCRIPTION}）。それ以外の失敗は、
 * クライアントが手元の assertion から自力で確認できる内容だけを述べる。
 *
 * jti によるリプレイ拒否は行わない。draft §4.4.3 は有効期間内の同一 ID-JAG の
 * 再提示（リフレッシュトークンの代替）を意図しており、束縛はクライアント認証と
 * client_id 一致、短い exp が担う。
 *
 * @throws {IdJagError} invalid_grant
 */
export async function verifyIdJagAssertion(options: {
  assertion: string;
  issuer: string;
  clientId: string;
  identityProviders: IdJagTrustedIdentityProvider[];
  now?: Date;
  clockSkewToleranceSec?: number;
}): Promise<IdJagAssertionPayload> {
  const leeway = options.clockSkewToleranceSec ?? DEFAULT_ASSERTION_CLOCK_SKEW_SEC;

  const parts = options.assertion.split('.');
  if (parts.length !== 3) {
    throw invalidAssertion('The provided assertion is not a valid JWS compact serialization');
  }
  const [headerB64, payloadB64, signatureB64] = parts as [string, string, string];

  let header: Record<string, unknown>;
  let payload: Record<string, unknown>;
  try {
    header = parseBase64UrlJson(headerB64);
    payload = parseBase64UrlJson(payloadB64);
  } catch {
    throw invalidAssertion('The provided assertion is not a valid JWS compact serialization');
  }

  // draft §4.4.1 / RFC 8725 §3.11: typ の検証で ID トークン等の流用（token
  // confusion）を構造的に拒否する。
  if (!isIdJagTyp(header['typ'])) {
    throw invalidAssertion(`The assertion typ must be ${ID_JAG_JWT_TYP}`);
  }

  const headerAlg = typeof header['alg'] === 'string' ? header['alg'] : undefined;
  if (!headerAlg || headerAlg === 'none') {
    throw invalidAssertion('The assertion alg is missing or "none"');
  }
  for (const field of FORBIDDEN_KEY_HEADERS) {
    if (field in header) {
      throw invalidAssertion(`The assertion JOSE header contains unsupported field: ${field}`);
    }
  }

  const iss = payload['iss'];
  if (typeof iss !== 'string' || iss.length === 0) {
    throw invalidAssertion(ASSERTION_UNTRUSTED_DESCRIPTION);
  }
  // draft §9.3: 自分が発行した ID-JAG を自分で引き換えると、SSO 用の assertion が
  // 同一ドメイン内のアクセストークンへ昇格する抜け道になる。信頼リストの構成に
  // かかわらず拒否する。
  if (iss === options.issuer) {
    throw invalidAssertion(
      'An assertion issued by this authorization server cannot be redeemed here',
    );
  }
  const identityProvider = options.identityProviders.find((idp) => idp.issuer === iss);
  if (identityProvider === undefined) {
    throw invalidAssertion(ASSERTION_UNTRUSTED_DESCRIPTION);
  }

  // 鍵選択: kid 一致を優先し、無ければ alg 一致の鍵を順次試行（core の
  // validateIdTokenHint と同じ規則）。鍵の alg とヘッダの alg の不一致は
  // 検証せず読み飛ばす（RFC 7515 §4.1.1 の鍵ごとの alg ピン留め）。
  const headerKid = typeof header['kid'] === 'string' ? header['kid'] : undefined;
  const candidates = headerKid
    ? identityProvider.jwks.keys.filter((key) => key.kid === headerKid)
    : identityProvider.jwks.keys.filter((key) => key.alg === headerAlg);

  const signingInput = `${headerB64}.${payloadB64}`;
  let signatureValid = false;
  for (const jwk of candidates) {
    if (jwk.alg !== headerAlg) {
      continue;
    }
    if (await verifySignature(signingInput, signatureB64, jwk)) {
      signatureValid = true;
      break;
    }
  }
  if (!signatureValid) {
    // 「鍵が見つからない」も「署名が壊れている」も同一文言（信頼構成の探索防止）。
    throw invalidAssertion(ASSERTION_UNTRUSTED_DESCRIPTION);
  }

  // draft §4.4.1: aud は自 AS の issuer identifier。文字列か、要素数 1 の配列のみ。
  const aud = payload['aud'];
  const audMatches =
    aud === options.issuer ||
    (Array.isArray(aud) && aud.length === 1 && aud[0] === options.issuer);
  if (!audMatches) {
    throw invalidAssertion('The assertion audience does not match this authorization server');
  }

  const nowSeconds = Math.floor((options.now ?? new Date()).getTime() / 1000);
  const exp = payload['exp'];
  if (typeof exp !== 'number') {
    throw invalidAssertion('The assertion is missing an exp claim');
  }
  if (exp + leeway < nowSeconds) {
    throw invalidAssertion('The assertion has expired');
  }
  const iat = payload['iat'];
  if (typeof iat !== 'number') {
    throw invalidAssertion('The assertion is missing an iat claim');
  }
  if (iat > nowSeconds + leeway) {
    throw invalidAssertion('The assertion iat is in the future');
  }
  const nbf = payload['nbf'];
  if (nbf !== undefined) {
    if (typeof nbf !== 'number' || nbf > nowSeconds + leeway) {
      throw invalidAssertion('The assertion is not yet valid');
    }
  }

  const jti = payload['jti'];
  if (typeof jti !== 'string' || jti.length === 0) {
    throw invalidAssertion('The assertion is missing a jti claim');
  }
  const sub = payload['sub'];
  if (typeof sub !== 'string' || sub.length === 0) {
    throw invalidAssertion('The assertion is missing a sub claim');
  }

  // draft §4.4.1: client_id クレームは「リクエストを認証したクライアント」と
  // 一致しなければならない（クライアント継続性）。
  const clientId = payload['client_id'];
  if (typeof clientId !== 'string' || clientId.length === 0) {
    throw invalidAssertion('The assertion is missing a client_id claim');
  }
  if (clientId !== options.clientId) {
    throw invalidAssertion('The assertion client_id does not match the authenticated client');
  }

  const scope = payload['scope'];
  if (scope !== undefined && typeof scope !== 'string') {
    throw invalidAssertion('The assertion scope claim must be a string');
  }

  const resource = payload['resource'];
  if (
    resource !== undefined &&
    typeof resource !== 'string' &&
    !(Array.isArray(resource) && resource.every((value) => typeof value === 'string'))
  ) {
    throw invalidAssertion('The assertion resource claim must be a string or an array of strings');
  }

  const authTime = typeof payload['auth_time'] === 'number' ? payload['auth_time'] : undefined;
  const acr = typeof payload['acr'] === 'string' ? payload['acr'] : undefined;
  const amr =
    Array.isArray(payload['amr']) && payload['amr'].every((value) => typeof value === 'string')
      ? (payload['amr'] as string[])
      : undefined;

  // act（draft §3.1 OPTIONAL / RFC 8693 §4.1）: 存在する場合は構造を検証して
  // そのまま引き継ぐ。黙って落とすと actor の記録が消えて委譲が impersonation に
  // 見えてしまうため、不明な形は拒否する（fail-closed）。
  const act = payload['act'];
  if (act !== undefined && !isValidActorChain(act)) {
    throw invalidAssertion('The assertion act claim is malformed');
  }

  return {
    iss,
    sub,
    aud: aud as string | string[],
    client_id: clientId,
    jti,
    exp,
    iat,
    ...(scope === undefined ? {} : { scope }),
    ...(resource === undefined ? {} : { resource: resource as string | string[] }),
    ...(authTime === undefined ? {} : { auth_time: authTime }),
    ...(acr === undefined ? {} : { acr }),
    ...(amr === undefined ? {} : { amr }),
    ...(act === undefined ? {} : { act: act as IdJagActor }),
  };
}

/**
 * ステップ 4: 実効 scope を導出する。
 *
 * 許可の上限は ID-JAG の scope クレーム（IdP が許可した範囲。draft §4.4.1 は
 * リソース AS がさらに部分集合へ絞ることを認める）。要求 scope があれば
 * その範囲内で縮小し、無ければ継承する。
 *
 * `offline_access` は常に除去する。jwt-bearer grant では refresh token を発行
 * しない（draft §4.4.3 SHOULD NOT。ID-JAG の再提示が代替）ため、実効 scope に
 * 残すと同意していない長期アクセスの表明になってしまう。
 *
 * @throws {IdJagError} invalid_scope
 */
export function resolveIdJagGrantScope(
  requestedScope: string | undefined,
  assertionScope: string | undefined,
): string[] {
  const granted = splitScope(assertionScope).filter((value) => value !== 'offline_access');
  const requested = splitScope(requestedScope);
  if (requested.length === 0) {
    return granted;
  }
  for (const value of requested) {
    if (!granted.includes(value)) {
      throw new IdJagError(
        'invalid_scope',
        'The requested scope exceeds the scope of the assertion',
      );
    }
  }
  return requested;
}

/**
 * 合成関数: jwt-bearer（ID-JAG）redemption の検証〜発行素材の導出。
 *
 * トークンの発行・保存・応答生成は行わないため、呼び出し側が core の
 * 発行パイプラインと組み合わせる。ID トークンと refresh token は発行しない
 * （jwt-bearer は OIDC の認証フローではなく、refresh token は draft §4.4.3 の
 * SHOULD NOT）。
 *
 * @throws {IdJagError}
 * @throws {RangeError} configuredExpiresIn が正の整数でない場合（設定ミス）
 */
export async function processIdJagRedemptionRequest(
  context: IdJagRedemptionContext,
): Promise<IdJagRedemptionGrant> {
  if (!Number.isInteger(context.configuredExpiresIn) || context.configuredExpiresIn <= 0) {
    throw new RangeError(
      `configuredExpiresIn must be a positive integer, received ${context.configuredExpiresIn}`,
    );
  }

  // クライアント認可を最初に行う。許可されていないクライアントには assertion の
  // 有効性すら判定させない（オラクルを与えない）。
  authorizeIdJagRedemptionClient(context.client);

  const parsed = parseIdJagRedemptionParams(context.params);

  const assertion = await verifyIdJagAssertion({
    assertion: parsed.assertion,
    issuer: context.issuer,
    clientId: context.client.clientId,
    identityProviders: context.identityProviders,
    ...(context.now === undefined ? {} : { now: context.now }),
    ...(context.clockSkewToleranceSec === undefined
      ? {}
      : { clockSkewToleranceSec: context.clockSkewToleranceSec }),
  });

  const scope = resolveIdJagGrantScope(parsed.scope, assertion.scope);

  const requestedResources =
    assertion.resource === undefined
      ? undefined
      : typeof assertion.resource === 'string'
        ? [assertion.resource]
        : [...assertion.resource];

  return {
    subject: assertion.sub,
    clientId: context.client.clientId,
    scope,
    ...(requestedResources === undefined ? {} : { requestedResources }),
    expiresIn: context.configuredExpiresIn,
    idpIssuer: assertion.iss,
    jti: assertion.jti,
    ...(assertion.auth_time === undefined ? {} : { authTime: assertion.auth_time }),
    ...(assertion.acr === undefined ? {} : { acr: assertion.acr }),
    ...(assertion.amr === undefined ? {} : { amr: assertion.amr }),
    ...(assertion.act === undefined ? {} : { actor: assertion.act }),
  };
}

/** 空文字・空白のみを「未指定」として扱う。 */
function optional(value: string | undefined): string | undefined {
  if (value === undefined) return undefined;
  const trimmed = value.trim();
  return trimmed.length === 0 ? undefined : trimmed;
}

function splitScope(scope: string | undefined): string[] {
  if (scope === undefined) return [];
  return [...new Set(scope.split(/\s+/).filter((value) => value.length > 0))];
}

function invalidAssertion(description: string): IdJagError {
  return new IdJagError('invalid_grant', description);
}

/**
 * RFC 8693 §4.1 の act claim 構造（`sub` 必須、`act` のネストは同形）を検証する。
 * ネストは「最外が現在の actor、最深が最も古い actor」のチェーンを表す。
 */
function isValidActorChain(value: unknown): value is IdJagActor {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return false;
  }
  const actor = value as { sub?: unknown; act?: unknown };
  if (typeof actor.sub !== 'string' || actor.sub.length === 0) {
    return false;
  }
  if (actor.act !== undefined && !isValidActorChain(actor.act)) {
    return false;
  }
  return true;
}

/**
 * RFC 7515 §4.1.9: typ は大文字小文字を無視して解釈され、`application/` 前置は
 * 省略形と等価に扱う。`oauth-id-jag+jwt` と `application/oauth-id-jag+jwt` を受ける。
 */
function isIdJagTyp(typ: unknown): boolean {
  if (typeof typ !== 'string') return false;
  const normalized = typ.toLowerCase();
  return normalized === ID_JAG_JWT_TYP || normalized === `application/${ID_JAG_JWT_TYP}`;
}

/** base64url（パディング無し）の JSON セグメントを厳格にパースする。 */
function parseBase64UrlJson(segment: string): Record<string, unknown> {
  if (!/^[A-Za-z0-9_-]+$/.test(segment)) {
    throw new Error('invalid base64url');
  }
  const base64 = segment.replace(/-/g, '+').replace(/_/g, '/');
  const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  const parsed: unknown = JSON.parse(new TextDecoder().decode(bytes));
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new Error('not a JSON object');
  }
  return parsed as Record<string, unknown>;
}

function base64UrlToArrayBuffer(segment: string): ArrayBuffer {
  if (!/^[A-Za-z0-9_-]*$/.test(segment)) {
    throw new Error('invalid base64url');
  }
  const base64 = segment.replace(/-/g, '+').replace(/_/g, '/');
  const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes.buffer;
}

/**
 * 1 つの JWK で compact JWS の署名を検証する。
 *
 * 検証パラメータは import 済み鍵の algorithm から導出する（ECDSA のハッシュは
 * 曲線に対応する。core の verify ヘルパーと同じ規則）。鍵の import 失敗・
 * アルゴリズム不一致・署名不一致はすべて false（呼び出し側が次の候補鍵を試すか、
 * 最終的に固定文言で拒否する）。
 */
async function verifySignature(
  signingInput: string,
  signatureB64: string,
  jwk: Jwk,
): Promise<boolean> {
  let signature: ArrayBuffer;
  try {
    signature = base64UrlToArrayBuffer(signatureB64);
  } catch {
    return false;
  }

  try {
    const algParams = extractAlgorithmParamsFromJwk(jwk as webcrypto.JsonWebKey);
    const publicKey = await crypto.subtle.importKey(
      'jwk',
      jwk as webcrypto.JsonWebKey,
      algParams,
      false,
      ['verify'],
    );

    const algorithm = publicKey.algorithm;
    let verifyParams: webcrypto.AlgorithmIdentifier | webcrypto.EcdsaParams;
    if (algorithm.name === 'RSASSA-PKCS1-v1_5') {
      verifyParams = { name: 'RSASSA-PKCS1-v1_5' };
    } else if (algorithm.name === 'ECDSA' && 'namedCurve' in algorithm) {
      const namedCurve = (algorithm as webcrypto.EcKeyAlgorithm).namedCurve;
      const hash =
        namedCurve === 'P-256' ? 'SHA-256' : namedCurve === 'P-384' ? 'SHA-384' : 'SHA-512';
      verifyParams = { name: 'ECDSA', hash };
    } else {
      return false;
    }

    return await crypto.subtle.verify(
      verifyParams,
      publicKey,
      signature,
      new TextEncoder().encode(signingInput),
    );
  } catch {
    return false;
  }
}
```

### index.ts（公開 API）

```typescript
/**
 * Identity Assertion Authorization Grant (ID-JAG) / Cross-App Access (XAA)
 * draft-ietf-oauth-identity-assertion-authz-grant-04
 *
 * **Experimental**: この機能の API は安定していない。マイナーリリースでも
 * 破壊的に変更されることがある。準拠先が IETF draft であり、改版でクレームや
 * 必須性が変わり得る点にも注意すること。
 *
 * `@maronn-openid-connect/core` とは別 package であり、CLI で `--enable id-jag` を
 * 明示したときのみ生成コードから利用される。
 *
 * 1 つの生成 OP に 2 つの役割を追加する:
 *
 * - **発行側（IdP）**: Token Exchange grant（RFC 8693）で
 *   `requested_token_type=urn:ietf:params:oauth:token-type:id-jag` を受け、
 *   自 OP 発行の ID トークンを検証して別トラストドメインのリソース AS 宛ての
 *   ID-JAG を発行する
 * - **受領側（リソース AS）**: `urn:ietf:params:oauth:grant-type:jwt-bearer`
 *   grant（RFC 7523）で信頼済み IdP の ID-JAG を検証し、自 OP のアクセス
 *   トークンの発行素材を導出する
 *
 * 既存の token-exchange 機能とは grant_type URN を共有するがコードは共有しない。
 * subject_token は ID トークンを必須対応とし、refresh token は設定（resolver の
 * 注入）で追加受理できる（draft §4.3 の MAY）。actor_token（本 OP 発行の
 * ID トークン）の受理と act claim の発行は、draft §9.7 の指針に沿った本機能
 * 独自の拡張として設定で有効化できる（既定は無効）。id_token 以外の actor_token
 * 種別は `IdJagActorTokenResolver` の注入で受けられる（リクエスト構造の検証は
 * ライブラリ、トークン内容の検証はリゾルバの責務）。
 * SAML subject / RAR / DPoP は非対応（notes リポジトリの仕様書の非目標を参照）。
 */
export {
  ACTOR_TOKEN_INVALID_DESCRIPTION,
  ASSERTION_UNTRUSTED_DESCRIPTION,
  SUBJECT_TOKEN_INVALID_DESCRIPTION,
  IdJagError,
  type IdJagErrorCode,
} from './errors.js';
export {
  ID_JAG_GRANT_PROFILE,
  ID_JAG_JWT_TYP,
  ID_JAG_TOKEN_TYPE,
  TOKEN_EXCHANGE_GRANT_TYPE,
  TOKEN_TYPE_ID_TOKEN,
  TOKEN_TYPE_REFRESH_TOKEN,
  authorizeIdJagIssuanceClient,
  buildIdJagClaims,
  buildIdJagIssuanceResponse,
  createIdJagJwt,
  matchesIdJagIssuanceRequest,
  parseIdJagIssuanceParams,
  processIdJagIssuanceRequest,
  resolveIdJagActor,
  resolveIdJagActorFromCustomToken,
  resolveIdJagSubject,
  resolveIdJagSubjectFromRefreshToken,
  validateIdJagAudience,
  validateIdJagScope,
  type IdJagActor,
  type IdJagActorTokenResolver,
  type IdJagActorTokenResolverInput,
  type IdJagClaims,
  type IdJagIssuanceContext,
  type IdJagIssuanceParseOptions,
  type IdJagIssuanceResponse,
  type IdJagSubject,
  type ParsedIdJagIssuanceParams,
} from './issue-id-jag.js';
export {
  DEFAULT_ASSERTION_CLOCK_SKEW_SEC,
  JWT_BEARER_GRANT_TYPE,
  authorizeIdJagRedemptionClient,
  parseIdJagRedemptionParams,
  processIdJagRedemptionRequest,
  resolveIdJagGrantScope,
  verifyIdJagAssertion,
  type IdJagAccessTokenInfo,
  type IdJagAssertionPayload,
  type IdJagRedemptionContext,
  type IdJagRedemptionGrant,
  type IdJagTrustedIdentityProvider,
  type ParsedIdJagRedemptionParams,
} from './redeem-id-jag.js';
```

## 単体テストの全文と解説

テストは発行側 94 件、受領側 59 件の計 153 件で、リポジトリの規約（should + 動詞、合格値の一意固定、`it` 内の条件分岐なし）に従う。
鍵と JWS はテスト専用フィクスチャで生成し、Web Crypto API だけで動くため edge-runtime 環境でもそのまま通る。

### test-helpers.ts（テスト専用フィクスチャ）

tsconfig の exclude 対象なので dist へは出ない。
`signTestJwt` は本体実装から独立した JWS 組み立てで、typ 改変や期限切れといった「本体では生成できない不正トークン」を作るために使う。

```typescript
/**
 * id-jag テスト専用フィクスチャ。
 *
 * tsconfig の exclude 対象なので dist へは出ない（公開 package に載らない）。
 * 鍵生成と JWS 組み立てを Web Crypto API だけで行い、edge-runtime 環境の
 * テストでそのまま動くようにしている。
 */
import type { webcrypto } from 'node:crypto';
import type { Jwk, JwkSet, SigningKey } from '@maronn-openid-connect/core';

export interface TestRs256Key {
  signingKey: SigningKey;
  jwk: Jwk;
  jwks: JwkSet;
}

/** RS256 鍵ペアを生成し、SigningKey と公開 JWK セットの両形式で返す。 */
export async function generateTestRs256Key(keyId: string): Promise<TestRs256Key> {
  const keyPair = await crypto.subtle.generateKey(
    {
      name: 'RSASSA-PKCS1-v1_5',
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: 'SHA-256',
    },
    true,
    ['sign', 'verify'],
  );
  const publicJwk = (await crypto.subtle.exportKey('jwk', keyPair.publicKey)) as Jwk;
  publicJwk.alg = 'RS256';
  publicJwk.use = 'sig';
  publicJwk.kid = keyId;
  return {
    signingKey: {
      privateKey: keyPair.privateKey,
      publicJwk: publicJwk as unknown as webcrypto.JsonWebKey,
      keyId,
    },
    jwk: publicJwk,
    jwks: { keys: [publicJwk] },
  };
}

function base64UrlFromBytes(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function base64UrlFromJson(value: Record<string, unknown>): string {
  return base64UrlFromBytes(new TextEncoder().encode(JSON.stringify(value)));
}

export function decodeJwtSegment(segment: string): Record<string, unknown> {
  const base64 = segment.replace(/-/g, '+').replace(/_/g, '/');
  const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return JSON.parse(new TextDecoder().decode(bytes)) as Record<string, unknown>;
}

export function decodeJwt(token: string): {
  header: Record<string, unknown>;
  payload: Record<string, unknown>;
} {
  const [headerB64 = '', payloadB64 = ''] = token.split('.');
  return {
    header: decodeJwtSegment(headerB64),
    payload: decodeJwtSegment(payloadB64),
  };
}

/**
 * 任意のヘッダーとペイロードで compact JWS を組み立てる。
 *
 * typ 改変や不正クレームのケースを作るためのテスト専用実装で、
 * 本体実装（createIdJagJwt）とは独立している。
 */
export async function signTestJwt(options: {
  header: Record<string, unknown>;
  payload: Record<string, unknown>;
  privateKey: CryptoKey;
}): Promise<string> {
  const encodedHeader = base64UrlFromJson(options.header);
  const encodedPayload = base64UrlFromJson(options.payload);
  const signingInput = `${encodedHeader}.${encodedPayload}`;
  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    options.privateKey,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${base64UrlFromBytes(new Uint8Array(signature))}`;
}

/** 署名部だけを別の値に差し替える（署名改ざんケース用）。 */
export function tamperSignature(token: string): string {
  const [headerB64 = '', payloadB64 = ''] = token.split('.');
  return `${headerB64}.${payloadB64}.AAAA`;
}
```

### issue-id-jag.test.ts（発行側）

```typescript
import { beforeAll, describe, expect, it } from 'vitest';
import {
  generateIdToken,
  type AuthenticationSessionResolver,
  type RefreshTokenInfo,
  type RefreshTokenResolver,
  type TokenClientInfo,
} from '@maronn-openid-connect/core';
import {
  ACTOR_TOKEN_INVALID_DESCRIPTION,
  IdJagError,
  SUBJECT_TOKEN_INVALID_DESCRIPTION,
} from './errors.js';
import {
  ID_JAG_GRANT_PROFILE,
  ID_JAG_JWT_TYP,
  ID_JAG_TOKEN_TYPE,
  TOKEN_EXCHANGE_GRANT_TYPE,
  TOKEN_TYPE_ID_TOKEN,
  TOKEN_TYPE_REFRESH_TOKEN,
  authorizeIdJagIssuanceClient,
  buildIdJagClaims,
  buildIdJagIssuanceResponse,
  createIdJagJwt,
  matchesIdJagIssuanceRequest,
  parseIdJagIssuanceParams,
  processIdJagIssuanceRequest,
  resolveIdJagActor,
  resolveIdJagActorFromCustomToken,
  resolveIdJagSubject,
  resolveIdJagSubjectFromRefreshToken,
  validateIdJagAudience,
  validateIdJagScope,
  type IdJagActor,
  type IdJagActorTokenResolver,
  type IdJagActorTokenResolverInput,
  type IdJagIssuanceContext,
} from './issue-id-jag.js';
import {
  decodeJwt,
  generateTestRs256Key,
  signTestJwt,
  type TestRs256Key,
} from './test-helpers.js';

/** IdP（自 OP）の issuer。subject_token の期待 iss であり ID-JAG の iss になる。 */
const ISSUER = 'https://idp.example.com';
/** ID-JAG の宛先（リソース AS の issuer）。 */
const AUDIENCE = 'https://rs-as.example.net';
const CLIENT_ID = 'xaa-client';

/** 2026-01-01T00:00:00Z。Unix epoch 秒で 1767225600。クレーム組み立ての固定時刻。 */
const NOW = new Date('2026-01-01T00:00:00Z');
const NOW_SECONDS = 1767225600;

let idpKey: TestRs256Key;
/** 現在時刻基準で有効な、CLIENT_ID 宛ての ID トークン。 */
let validIdToken: string;

beforeAll(async () => {
  idpKey = await generateTestRs256Key('idp-rs256-key');
  validIdToken = await mintIdToken({});
});

/**
 * core の generateIdToken で ID トークンを作る。exp / iat は実時刻基準
 * （resolveIdJagSubject が委譲する core の検証は実時刻で判定するため）。
 */
async function mintIdToken(overrides: Record<string, unknown>): Promise<string> {
  const nowSeconds = Math.floor(Date.now() / 1000);
  return generateIdToken({
    payload: {
      iss: ISSUER,
      sub: 'user-1',
      aud: CLIENT_ID,
      exp: nowSeconds + 3600,
      iat: nowSeconds,
      auth_time: nowSeconds - 10,
      acr: 'urn:mace:incommon:iap:silver',
      amr: ['pwd', 'mfa'],
      ...overrides,
    },
    privateKey: idpKey.signingKey.privateKey,
    keyId: idpKey.signingKey.keyId,
  });
}

function confidentialClient(overrides: Partial<TokenClientInfo> = {}): TokenClientInfo {
  return {
    clientId: CLIENT_ID,
    clientSecret: 'secret',
    grantTypes: ['authorization_code', TOKEN_EXCHANGE_GRANT_TYPE],
    tokenEndpointAuthMethod: 'client_secret_basic',
    ...overrides,
  };
}

function validParams(overrides: Record<string, string | undefined> = {}): Record<string, string> {
  const base: Record<string, string | undefined> = {
    grant_type: TOKEN_EXCHANGE_GRANT_TYPE,
    requested_token_type: ID_JAG_TOKEN_TYPE,
    subject_token: validIdToken,
    subject_token_type: TOKEN_TYPE_ID_TOKEN,
    audience: AUDIENCE,
    scope: 'openid profile',
    ...overrides,
  };
  const params: Record<string, string> = {};
  for (const [key, value] of Object.entries(base)) {
    if (value !== undefined) params[key] = value;
  }
  return params;
}

function issuanceContext(overrides: Partial<IdJagIssuanceContext> = {}): IdJagIssuanceContext {
  return {
    params: validParams(),
    client: confidentialClient(),
    issuer: ISSUER,
    jwks: idpKey.jwks,
    signingKey: idpKey.signingKey,
    allowedAudiences: [AUDIENCE],
    lifetimeSeconds: 300,
    now: NOW,
    ...overrides,
  };
}

describe('id-jag issuance constants', () => {
  // draft §4.3 / RFC 8693 §3
  it('should expose the ID-JAG token type URN', () => {
    expect(ID_JAG_TOKEN_TYPE).toBe('urn:ietf:params:oauth:token-type:id-jag');
  });

  it('should expose the id_token subject token type URN', () => {
    expect(TOKEN_TYPE_ID_TOKEN).toBe('urn:ietf:params:oauth:token-type:id_token');
  });

  // draft §3.1: JWT header typ (RFC 8725 §3.11 explicit typing)
  it('should expose the oauth-id-jag+jwt typ value', () => {
    expect(ID_JAG_JWT_TYP).toBe('oauth-id-jag+jwt');
  });

  // draft §7.2 / §8
  it('should expose the grant profile identifier', () => {
    expect(ID_JAG_GRANT_PROFILE).toBe('urn:ietf:params:oauth:grant-profile:id-jag');
  });
});

describe('matchesIdJagIssuanceRequest', () => {
  it('should match a token-exchange request that asks for an ID-JAG', () => {
    expect(matchesIdJagIssuanceRequest(validParams())).toBe(true);
  });

  it('should not match a token-exchange request without requested_token_type', () => {
    expect(matchesIdJagIssuanceRequest(validParams({ requested_token_type: undefined }))).toBe(
      false,
    );
  });

  it('should not match a token-exchange request for an access token', () => {
    expect(
      matchesIdJagIssuanceRequest(
        validParams({ requested_token_type: 'urn:ietf:params:oauth:token-type:access_token' }),
      ),
    ).toBe(false);
  });

  it('should not match other grant types', () => {
    expect(matchesIdJagIssuanceRequest(validParams({ grant_type: 'authorization_code' }))).toBe(
      false,
    );
  });
});

describe('authorizeIdJagIssuanceClient', () => {
  it('should accept a confidential client registered for the token-exchange grant', () => {
    expect(() => authorizeIdJagIssuanceClient(confidentialClient())).not.toThrow();
  });

  // RFC 7591 §2: grantTypes 未指定は ['authorization_code'] 扱い
  it('should reject a client without registered grantTypes with unauthorized_client', () => {
    const client = confidentialClient();
    delete (client as { grantTypes?: string[] }).grantTypes;
    expect(() => authorizeIdJagIssuanceClient(client)).toThrow(
      new IdJagError(
        'unauthorized_client',
        'The client is not authorized to use the token-exchange grant type',
      ),
    );
  });

  it('should reject a client not registered for the token-exchange grant', () => {
    const client = confidentialClient({ grantTypes: ['authorization_code'] });
    expect(() => authorizeIdJagIssuanceClient(client)).toThrow(
      new IdJagError(
        'unauthorized_client',
        'The client is not authorized to use the token-exchange grant type',
      ),
    );
  });

  // draft §9.1: confidential client 限定
  it('should reject a public client with unauthorized_client', () => {
    const client = confidentialClient({
      tokenEndpointAuthMethod: 'none',
      clientSecret: undefined,
    });
    expect(() => authorizeIdJagIssuanceClient(client)).toThrow(
      new IdJagError('unauthorized_client', 'Public clients are not allowed to request an ID-JAG'),
    );
  });
});

describe('parseIdJagIssuanceParams', () => {
  it('should return the typed parameters', () => {
    expect(parseIdJagIssuanceParams(validParams({ resource: 'https://api.example.net/files' }))).toEqual({
      subjectToken: validIdToken,
      subjectTokenType: TOKEN_TYPE_ID_TOKEN,
      audience: AUDIENCE,
      scope: 'openid profile',
      resource: 'https://api.example.net/files',
    });
  });

  it('should treat omitted scope and resource as undefined', () => {
    expect(parseIdJagIssuanceParams(validParams({ scope: undefined }))).toEqual({
      subjectToken: validIdToken,
      subjectTokenType: TOKEN_TYPE_ID_TOKEN,
      audience: AUDIENCE,
      scope: undefined,
      resource: undefined,
    });
  });

  it('should reject a missing subject_token with invalid_request', () => {
    expect(() => parseIdJagIssuanceParams(validParams({ subject_token: undefined }))).toThrow(
      new IdJagError('invalid_request', 'subject_token is required'),
    );
  });

  it('should reject a missing subject_token_type with invalid_request', () => {
    expect(() => parseIdJagIssuanceParams(validParams({ subject_token_type: undefined }))).toThrow(
      new IdJagError('invalid_request', 'subject_token_type is required'),
    );
  });

  // 非目標: saml2 / access_token の subject は受けない
  it('should reject a saml2 subject_token_type with invalid_request', () => {
    expect(() =>
      parseIdJagIssuanceParams(
        validParams({ subject_token_type: 'urn:ietf:params:oauth:token-type:saml2' }),
      ),
    ).toThrow(
      new IdJagError(
        'invalid_request',
        `Unsupported subject_token_type for ID-JAG issuance. Only ${TOKEN_TYPE_ID_TOKEN} is supported.`,
      ),
    );
  });

  // refresh subject（draft §4.3 MAY）は受理ポリシーで有効化したときだけ受ける
  it('should reject a refresh_token subject_token_type when not enabled', () => {
    expect(() =>
      parseIdJagIssuanceParams(validParams({ subject_token_type: TOKEN_TYPE_REFRESH_TOKEN })),
    ).toThrow(
      new IdJagError(
        'invalid_request',
        `Unsupported subject_token_type for ID-JAG issuance. Only ${TOKEN_TYPE_ID_TOKEN} is supported.`,
      ),
    );
  });

  it('should accept a refresh_token subject_token_type when enabled', () => {
    expect(
      parseIdJagIssuanceParams(
        validParams({ subject_token: 'rt-1', subject_token_type: TOKEN_TYPE_REFRESH_TOKEN }),
        { allowRefreshTokenSubjects: true },
      ),
    ).toEqual({
      subjectToken: 'rt-1',
      subjectTokenType: TOKEN_TYPE_REFRESH_TOKEN,
      audience: AUDIENCE,
      scope: 'openid profile',
      resource: undefined,
    });
  });

  it('should list both supported subject types when refresh subjects are enabled', () => {
    expect(() =>
      parseIdJagIssuanceParams(
        validParams({ subject_token_type: 'urn:ietf:params:oauth:token-type:saml2' }),
        { allowRefreshTokenSubjects: true },
      ),
    ).toThrow(
      new IdJagError(
        'invalid_request',
        `Unsupported subject_token_type for ID-JAG issuance. Only ${TOKEN_TYPE_ID_TOKEN} or ${TOKEN_TYPE_REFRESH_TOKEN} is supported.`,
      ),
    );
  });

  // draft §4.3: audience は REQUIRED
  it('should reject a missing audience with invalid_request', () => {
    expect(() => parseIdJagIssuanceParams(validParams({ audience: undefined }))).toThrow(
      new IdJagError('invalid_request', 'audience is required'),
    );
  });

  it('should treat a whitespace-only audience as missing', () => {
    expect(() => parseIdJagIssuanceParams(validParams({ audience: '   ' }))).toThrow(
      new IdJagError('invalid_request', 'audience is required'),
    );
  });

  // RFC 8707 §2: resource は絶対 URI・fragment 禁止
  it('should reject a relative resource with invalid_request', () => {
    expect(() => parseIdJagIssuanceParams(validParams({ resource: '/files' }))).toThrow(
      new IdJagError(
        'invalid_request',
        'resource must be an absolute URI without a fragment component',
      ),
    );
  });

  it('should reject a resource with a fragment with invalid_request', () => {
    expect(() =>
      parseIdJagIssuanceParams(validParams({ resource: 'https://api.example.net/#top' })),
    ).toThrow(IdJagError);
  });

  // actor 受理を有効化していない構成では fail-safe に拒否する
  it('should reject an actor_token when not enabled', () => {
    expect(() => parseIdJagIssuanceParams(validParams({ actor_token: 'some-token' }))).toThrow(
      new IdJagError('invalid_request', 'actor_token is not supported for ID-JAG issuance'),
    );
  });

  it('should reject an actor_token_type when not enabled', () => {
    expect(() =>
      parseIdJagIssuanceParams(
        validParams({ actor_token_type: 'urn:ietf:params:oauth:token-type:access_token' }),
      ),
    ).toThrow(IdJagError);
  });

  it('should return the actor_token when actor tokens are enabled', () => {
    expect(
      parseIdJagIssuanceParams(
        validParams({ actor_token: 'actor-id-token', actor_token_type: TOKEN_TYPE_ID_TOKEN }),
        { allowActorTokens: true },
      ),
    ).toEqual({
      subjectToken: validIdToken,
      subjectTokenType: TOKEN_TYPE_ID_TOKEN,
      audience: AUDIENCE,
      scope: 'openid profile',
      resource: undefined,
      actorToken: 'actor-id-token',
      actorTokenType: TOKEN_TYPE_ID_TOKEN,
    });
  });

  // RFC 8693 §2.1: actor_token と actor_token_type の対応規則
  it('should reject an actor_token without actor_token_type when enabled', () => {
    expect(() =>
      parseIdJagIssuanceParams(validParams({ actor_token: 'actor-id-token' }), {
        allowActorTokens: true,
      }),
    ).toThrow(
      new IdJagError('invalid_request', 'actor_token_type is required when actor_token is present'),
    );
  });

  it('should reject an actor_token_type without actor_token when enabled', () => {
    expect(() =>
      parseIdJagIssuanceParams(validParams({ actor_token_type: TOKEN_TYPE_ID_TOKEN }), {
        allowActorTokens: true,
      }),
    ).toThrow(
      new IdJagError('invalid_request', 'actor_token_type must not be present without actor_token'),
    );
  });

  it('should reject a non-id_token actor_token_type when enabled', () => {
    expect(() =>
      parseIdJagIssuanceParams(
        validParams({
          actor_token: 'actor-token',
          actor_token_type: 'urn:ietf:params:oauth:token-type:access_token',
        }),
        { allowActorTokens: true },
      ),
    ).toThrow(
      new IdJagError(
        'invalid_request',
        `Unsupported actor_token_type for ID-JAG issuance. Only ${TOKEN_TYPE_ID_TOKEN} is supported.`,
      ),
    );
  });

  // リゾルバ注入時の構造検証: 種別は通すが、対応規則と gate はそのまま働く
  it('should return a custom actor_token_type when custom types are allowed', () => {
    expect(
      parseIdJagIssuanceParams(
        validParams({
          actor_token: 'opaque-actor-token',
          actor_token_type: 'urn:example:token-type:badge',
        }),
        { allowActorTokens: true, allowCustomActorTokenTypes: true },
      ),
    ).toEqual({
      subjectToken: validIdToken,
      subjectTokenType: TOKEN_TYPE_ID_TOKEN,
      audience: AUDIENCE,
      scope: 'openid profile',
      resource: undefined,
      actorToken: 'opaque-actor-token',
      actorTokenType: 'urn:example:token-type:badge',
    });
  });

  // allowActorTokens は親スイッチ: リゾルバ受理の構成でも無効化が優先される
  it('should reject an actor_token while actor tokens are disabled even when custom types are allowed', () => {
    expect(() =>
      parseIdJagIssuanceParams(
        validParams({
          actor_token: 'opaque-actor-token',
          actor_token_type: 'urn:example:token-type:badge',
        }),
        { allowCustomActorTokenTypes: true },
      ),
    ).toThrow(
      new IdJagError('invalid_request', 'actor_token is not supported for ID-JAG issuance'),
    );
  });

  // 非目標: RAR
  it('should reject authorization_details with invalid_request', () => {
    expect(() =>
      parseIdJagIssuanceParams(validParams({ authorization_details: '[{"type":"x"}]' })),
    ).toThrow(
      new IdJagError('invalid_request', 'authorization_details is not supported for ID-JAG issuance'),
    );
  });
});

describe('resolveIdJagSubject', () => {
  it('should return the subject material from a valid ID Token', async () => {
    const nowSeconds = Math.floor(Date.now() / 1000);
    const idToken = await mintIdToken({ auth_time: nowSeconds - 20 });
    await expect(
      resolveIdJagSubject({
        subjectToken: idToken,
        issuer: ISSUER,
        clientId: CLIENT_ID,
        jwks: idpKey.jwks,
      }),
    ).resolves.toEqual({
      sub: 'user-1',
      authTime: nowSeconds - 20,
      acr: 'urn:mace:incommon:iap:silver',
      amr: ['pwd', 'mfa'],
    });
  });

  it('should omit auth context fields the ID Token does not carry', async () => {
    const idToken = await mintIdToken({ auth_time: undefined, acr: undefined, amr: undefined });
    await expect(
      resolveIdJagSubject({
        subjectToken: idToken,
        issuer: ISSUER,
        clientId: CLIENT_ID,
        jwks: idpKey.jwks,
      }),
    ).resolves.toEqual({ sub: 'user-1' });
  });

  // draft §4.3.3: assertion の audience はクライアント認証の client_id と一致しなければならない
  it('should reject an ID Token issued to another client with the fixed description', async () => {
    const idToken = await mintIdToken({ aud: 'another-client' });
    await expect(
      resolveIdJagSubject({
        subjectToken: idToken,
        issuer: ISSUER,
        clientId: CLIENT_ID,
        jwks: idpKey.jwks,
      }),
    ).rejects.toThrow(new IdJagError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION));
  });

  // オラクル排除: 失敗種別によらず同じ応答になる
  it('should reject a tampered ID Token with the same fixed description', async () => {
    const [headerB64 = '', payloadB64 = ''] = validIdToken.split('.');
    await expect(
      resolveIdJagSubject({
        subjectToken: `${headerB64}.${payloadB64}.AAAA`,
        issuer: ISSUER,
        clientId: CLIENT_ID,
        jwks: idpKey.jwks,
      }),
    ).rejects.toThrow(new IdJagError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION));
  });

  it('should reject an expired ID Token with the same fixed description', async () => {
    // core の generateIdToken は期限切れ payload の生成自体を拒否するため、
    // 期限切れトークンはテスト用の JWS 手組みで作る（署名は正当なまま）。
    const nowSeconds = Math.floor(Date.now() / 1000);
    const idToken = await signTestJwt({
      header: { alg: 'RS256', typ: 'JWT', kid: idpKey.signingKey.keyId },
      payload: {
        iss: ISSUER,
        sub: 'user-1',
        aud: CLIENT_ID,
        exp: nowSeconds - 3600,
        iat: nowSeconds - 7200,
      },
      privateKey: idpKey.signingKey.privateKey,
    });
    await expect(
      resolveIdJagSubject({
        subjectToken: idToken,
        issuer: ISSUER,
        clientId: CLIENT_ID,
        jwks: idpKey.jwks,
      }),
    ).rejects.toThrow(new IdJagError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION));
  });

  it('should reject an ID Token from another issuer with the same fixed description', async () => {
    const idToken = await mintIdToken({ iss: 'https://other-idp.example.com' });
    await expect(
      resolveIdJagSubject({
        subjectToken: idToken,
        issuer: ISSUER,
        clientId: CLIENT_ID,
        jwks: idpKey.jwks,
      }),
    ).rejects.toThrow(new IdJagError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION));
  });
});

describe('validateIdJagAudience', () => {
  it('should accept an allow-listed audience', () => {
    expect(() =>
      validateIdJagAudience({
        audience: AUDIENCE,
        issuer: ISSUER,
        allowedAudiences: [AUDIENCE],
      }),
    ).not.toThrow();
  });

  it('should reject an audience outside the allow list with invalid_target', () => {
    expect(() =>
      validateIdJagAudience({
        audience: 'https://unknown.example.org',
        issuer: ISSUER,
        allowedAudiences: [AUDIENCE],
      }),
    ).toThrow(
      new IdJagError('invalid_target', 'The requested audience is not allowed for ID-JAG issuance'),
    );
  });

  it('should reject every audience when the allow list is empty', () => {
    expect(() =>
      validateIdJagAudience({ audience: AUDIENCE, issuer: ISSUER, allowedAudiences: [] }),
    ).toThrow(IdJagError);
  });

  // draft §9.3: クロスドメイン限定。自分宛ての発行は許可リストに関係なく拒否する
  it('should reject the issuer itself as audience even when allow-listed', () => {
    expect(() =>
      validateIdJagAudience({ audience: ISSUER, issuer: ISSUER, allowedAudiences: [ISSUER] }),
    ).toThrow(
      new IdJagError(
        'invalid_target',
        'The requested audience must belong to a different trust domain than this authorization server',
      ),
    );
  });
});

describe('validateIdJagScope', () => {
  it('should pass the requested scope through when no allow list is configured', () => {
    expect(validateIdJagScope('openid profile', undefined)).toEqual(['openid', 'profile']);
  });

  it('should return an empty scope when nothing is requested', () => {
    expect(validateIdJagScope(undefined, undefined)).toEqual([]);
  });

  it('should deduplicate repeated scope values', () => {
    expect(validateIdJagScope('openid openid profile', undefined)).toEqual(['openid', 'profile']);
  });

  it('should accept a subset of the configured allow list', () => {
    expect(validateIdJagScope('openid', ['openid', 'profile'])).toEqual(['openid']);
  });

  it('should reject a scope outside the allow list with invalid_scope', () => {
    expect(() => validateIdJagScope('openid admin', ['openid', 'profile'])).toThrow(
      new IdJagError(
        'invalid_scope',
        'The requested scope exceeds the scopes allowed for ID-JAG issuance',
      ),
    );
  });
});

describe('buildIdJagClaims', () => {
  // draft §3.1 の REQUIRED クレーム一式
  it('should build the required claims from the subject and request', () => {
    const claims = buildIdJagClaims({
      issuer: ISSUER,
      subject: { sub: 'user-1' },
      audience: AUDIENCE,
      clientId: CLIENT_ID,
      scope: ['openid', 'profile'],
      lifetimeSeconds: 300,
      now: NOW,
    });
    expect(claims).toMatchObject({
      iss: ISSUER,
      sub: 'user-1',
      aud: AUDIENCE,
      client_id: CLIENT_ID,
      exp: NOW_SECONDS + 300,
      iat: NOW_SECONDS,
      scope: 'openid profile',
    });
    expect(typeof claims.jti).toBe('string');
    // 256bit を base64url した長さ（43 文字）
    expect(claims.jti.length).toBe(43);
  });

  it('should omit the scope claim when no scope was granted', () => {
    const claims = buildIdJagClaims({
      issuer: ISSUER,
      subject: { sub: 'user-1' },
      audience: AUDIENCE,
      clientId: CLIENT_ID,
      scope: [],
      lifetimeSeconds: 300,
      now: NOW,
    });
    expect('scope' in claims).toBe(false);
  });

  it('should carry resource and auth context claims when present', () => {
    const claims = buildIdJagClaims({
      issuer: ISSUER,
      subject: { sub: 'user-1', authTime: NOW_SECONDS - 60, acr: 'silver', amr: ['pwd'] },
      audience: AUDIENCE,
      clientId: CLIENT_ID,
      scope: [],
      resource: 'https://api.example.net/files',
      lifetimeSeconds: 300,
      now: NOW,
    });
    expect(claims).toMatchObject({
      resource: 'https://api.example.net/files',
      auth_time: NOW_SECONDS - 60,
      acr: 'silver',
      amr: ['pwd'],
    });
  });

  it('should reject a non-positive lifetime with a RangeError', () => {
    expect(() =>
      buildIdJagClaims({
        issuer: ISSUER,
        subject: { sub: 'user-1' },
        audience: AUDIENCE,
        clientId: CLIENT_ID,
        scope: [],
        lifetimeSeconds: 0,
        now: NOW,
      }),
    ).toThrow(RangeError);
  });
});

describe('createIdJagJwt', () => {
  // draft §3.1: typ は oauth-id-jag+jwt（RFC 8725 §3.11）
  it('should set alg RS256, the ID-JAG typ and the kid in the JOSE header', async () => {
    const claims = buildIdJagClaims({
      issuer: ISSUER,
      subject: { sub: 'user-1' },
      audience: AUDIENCE,
      clientId: CLIENT_ID,
      scope: ['openid'],
      lifetimeSeconds: 300,
      now: NOW,
    });
    const jwt = await createIdJagJwt({ claims, signingKey: idpKey.signingKey });
    const { header, payload } = decodeJwt(jwt);
    expect(header).toEqual({
      alg: 'RS256',
      typ: 'oauth-id-jag+jwt',
      kid: 'idp-rs256-key',
    });
    expect(payload).toEqual({ ...claims });
  });

  it('should produce a verifiable RS256 signature', async () => {
    const claims = buildIdJagClaims({
      issuer: ISSUER,
      subject: { sub: 'user-1' },
      audience: AUDIENCE,
      clientId: CLIENT_ID,
      scope: [],
      lifetimeSeconds: 300,
      now: NOW,
    });
    const jwt = await createIdJagJwt({ claims, signingKey: idpKey.signingKey });
    const [headerB64 = '', payloadB64 = '', signatureB64 = ''] = jwt.split('.');
    const publicKey = await crypto.subtle.importKey(
      'jwk',
      idpKey.jwk as JsonWebKey,
      { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
      false,
      ['verify'],
    );
    const base64 = signatureB64.replace(/-/g, '+').replace(/_/g, '/');
    const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
    const signature = Uint8Array.from(atob(padded), (char) => char.charCodeAt(0));
    await expect(
      crypto.subtle.verify(
        'RSASSA-PKCS1-v1_5',
        publicKey,
        signature,
        new TextEncoder().encode(`${headerB64}.${payloadB64}`),
      ),
    ).resolves.toBe(true);
  });
});

describe('buildIdJagIssuanceResponse', () => {
  // draft §4.3.4: token_type は N_A、issued_token_type は ID-JAG の URN
  it('should build the RFC 8693 response with token_type N_A', () => {
    expect(
      buildIdJagIssuanceResponse({ idJag: 'jwt-value', expiresIn: 300, scope: ['openid'] }),
    ).toEqual({
      access_token: 'jwt-value',
      issued_token_type: 'urn:ietf:params:oauth:token-type:id-jag',
      token_type: 'N_A',
      expires_in: 300,
      scope: 'openid',
    });
  });

  it('should return an empty scope string when no scope was granted', () => {
    expect(buildIdJagIssuanceResponse({ idJag: 'jwt-value', expiresIn: 300, scope: [] })).toEqual({
      access_token: 'jwt-value',
      issued_token_type: 'urn:ietf:params:oauth:token-type:id-jag',
      token_type: 'N_A',
      expires_in: 300,
      scope: '',
    });
  });
});

describe('processIdJagIssuanceRequest', () => {
  it('should issue an ID-JAG for a valid request', async () => {
    const response = await processIdJagIssuanceRequest(issuanceContext());
    expect(response.issued_token_type).toBe('urn:ietf:params:oauth:token-type:id-jag');
    expect(response.token_type).toBe('N_A');
    expect(response.expires_in).toBe(300);
    expect(response.scope).toBe('openid profile');

    const { header, payload } = decodeJwt(response.access_token);
    expect(header['typ']).toBe('oauth-id-jag+jwt');
    expect(header['alg']).toBe('RS256');
    expect(payload).toMatchObject({
      iss: ISSUER,
      sub: 'user-1',
      aud: AUDIENCE,
      client_id: CLIENT_ID,
      exp: NOW_SECONDS + 300,
      iat: NOW_SECONDS,
      scope: 'openid profile',
    });
  });

  it('should reject an unauthorized client before validating the subject_token', async () => {
    await expect(
      processIdJagIssuanceRequest(
        issuanceContext({
          client: confidentialClient({ grantTypes: ['authorization_code'] }),
          params: validParams({ subject_token: 'never-validated' }),
        }),
      ),
    ).rejects.toThrow(
      new IdJagError(
        'unauthorized_client',
        'The client is not authorized to use the token-exchange grant type',
      ),
    );
  });

  it('should reject an ID Token issued to another client with invalid_request', async () => {
    const foreignIdToken = await mintIdToken({ aud: 'another-client' });
    await expect(
      processIdJagIssuanceRequest(
        issuanceContext({ params: validParams({ subject_token: foreignIdToken }) }),
      ),
    ).rejects.toThrow(new IdJagError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION));
  });

  it('should reject an audience outside the allow list with invalid_target', async () => {
    await expect(
      processIdJagIssuanceRequest(
        issuanceContext({ params: validParams({ audience: 'https://unknown.example.org' }) }),
      ),
    ).rejects.toThrow(
      new IdJagError('invalid_target', 'The requested audience is not allowed for ID-JAG issuance'),
    );
  });

  it('should reject the issuer itself as audience with invalid_target', async () => {
    await expect(
      processIdJagIssuanceRequest(
        issuanceContext({
          params: validParams({ audience: ISSUER }),
          allowedAudiences: [AUDIENCE, ISSUER],
        }),
      ),
    ).rejects.toThrow(
      new IdJagError(
        'invalid_target',
        'The requested audience must belong to a different trust domain than this authorization server',
      ),
    );
  });

  it('should reject a scope outside the configured allow list with invalid_scope', async () => {
    await expect(
      processIdJagIssuanceRequest(
        issuanceContext({
          allowedScopes: ['openid'],
          params: validParams({ scope: 'openid profile' }),
        }),
      ),
    ).rejects.toThrow(
      new IdJagError(
        'invalid_scope',
        'The requested scope exceeds the scopes allowed for ID-JAG issuance',
      ),
    );
  });

  it('should omit the scope claim and return an empty scope when none was requested', async () => {
    const response = await processIdJagIssuanceRequest(
      issuanceContext({ params: validParams({ scope: undefined }) }),
    );
    expect(response.scope).toBe('');
    const { payload } = decodeJwt(response.access_token);
    expect('scope' in payload).toBe(false);
  });

  it('should carry the resource parameter into the resource claim', async () => {
    const response = await processIdJagIssuanceRequest(
      issuanceContext({ params: validParams({ resource: 'https://api.example.net/files' }) }),
    );
    const { payload } = decodeJwt(response.access_token);
    expect(payload['resource']).toBe('https://api.example.net/files');
  });
});

function refreshTokenInfoFixture(overrides: Partial<RefreshTokenInfo> = {}): RefreshTokenInfo {
  const nowSeconds = Math.floor(Date.now() / 1000);
  return {
    subject: 'user-1',
    clientId: CLIENT_ID,
    scope: ['openid', 'profile'],
    expiresAt: nowSeconds + 3600,
    used: false,
    grantId: 'grant-1',
    originalIssuedAt: nowSeconds - 60,
    authTime: nowSeconds - 120,
    acr: 'urn:mace:incommon:iap:silver',
    amr: ['pwd', 'mfa'],
    ...overrides,
  };
}

/** 'rt-1' だけを解決する resolver。family 失効の呼び出しを revokedGrants に記録する。 */
function refreshResolverFor(
  info: RefreshTokenInfo | null,
  revokedGrants: string[] = [],
): RefreshTokenResolver {
  return {
    resolve: async (token) => (token === 'rt-1' ? info : null),
    revokeRefreshToken: async () => {},
    revokeTokensByGrantId: async (grantId) => {
      revokedGrants.push(grantId);
    },
  };
}

function sessionResolverFor(liveSessionId: string | null): AuthenticationSessionResolver {
  return {
    findSession: async (sessionId) =>
      liveSessionId !== null && sessionId === liveSessionId
        ? { subject: 'user-1', authTime: Math.floor(Date.now() / 1000) - 120 }
        : null,
  };
}

describe('resolveIdJagSubjectFromRefreshToken', () => {
  // draft §4.3.3: RT の保存情報から subject のクレームを組み立てる
  it('should return the subject material from a valid refresh token', async () => {
    const info = refreshTokenInfoFixture();
    await expect(
      resolveIdJagSubjectFromRefreshToken({
        refreshToken: 'rt-1',
        clientId: CLIENT_ID,
        refreshTokenResolver: refreshResolverFor(info),
      }),
    ).resolves.toEqual({
      sub: 'user-1',
      authTime: info.authTime,
      acr: 'urn:mace:incommon:iap:silver',
      amr: ['pwd', 'mfa'],
    });
  });

  it('should reject an unknown refresh token with the fixed description', async () => {
    await expect(
      resolveIdJagSubjectFromRefreshToken({
        refreshToken: 'rt-1',
        clientId: CLIENT_ID,
        refreshTokenResolver: refreshResolverFor(null),
      }),
    ).rejects.toThrow(new IdJagError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION));
  });

  // OAuth 2.1 §4.3.1: rotation 済み RT の再提示は refresh grant と同じく family を失効する
  it('should reject a rotated refresh token and revoke its token family', async () => {
    const revokedGrants: string[] = [];
    await expect(
      resolveIdJagSubjectFromRefreshToken({
        refreshToken: 'rt-1',
        clientId: CLIENT_ID,
        refreshTokenResolver: refreshResolverFor(
          refreshTokenInfoFixture({ used: true }),
          revokedGrants,
        ),
      }),
    ).rejects.toThrow(new IdJagError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION));
    expect(revokedGrants).toEqual(['grant-1']);
  });

  it('should reject a refresh token issued to another client with the fixed description', async () => {
    await expect(
      resolveIdJagSubjectFromRefreshToken({
        refreshToken: 'rt-1',
        clientId: CLIENT_ID,
        refreshTokenResolver: refreshResolverFor(
          refreshTokenInfoFixture({ clientId: 'another-client' }),
        ),
      }),
    ).rejects.toThrow(new IdJagError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION));
  });

  it('should reject an expired refresh token with the fixed description', async () => {
    const nowSeconds = Math.floor(Date.now() / 1000);
    await expect(
      resolveIdJagSubjectFromRefreshToken({
        refreshToken: 'rt-1',
        clientId: CLIENT_ID,
        refreshTokenResolver: refreshResolverFor(
          refreshTokenInfoFixture({ expiresAt: nowSeconds - 60 }),
        ),
      }),
    ).rejects.toThrow(new IdJagError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION));
  });

  // ID トークン（Identity Assertion）が存在し得ない grant の RT は代替にならない
  it('should reject a refresh token whose grant lacks the openid scope', async () => {
    await expect(
      resolveIdJagSubjectFromRefreshToken({
        refreshToken: 'rt-1',
        clientId: CLIENT_ID,
        refreshTokenResolver: refreshResolverFor(
          refreshTokenInfoFixture({ scope: ['profile', 'email'] }),
        ),
      }),
    ).rejects.toThrow(new IdJagError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION));
  });

  it('should accept an online refresh token while its session is alive', async () => {
    await expect(
      resolveIdJagSubjectFromRefreshToken({
        refreshToken: 'rt-1',
        clientId: CLIENT_ID,
        refreshTokenResolver: refreshResolverFor(
          refreshTokenInfoFixture({ sessionId: 'session-1' }),
        ),
        authenticationSessionResolver: sessionResolverFor('session-1'),
      }),
    ).resolves.toMatchObject({ sub: 'user-1' });
  });

  it('should reject an online refresh token after its session ended', async () => {
    await expect(
      resolveIdJagSubjectFromRefreshToken({
        refreshToken: 'rt-1',
        clientId: CLIENT_ID,
        refreshTokenResolver: refreshResolverFor(
          refreshTokenInfoFixture({ sessionId: 'session-1' }),
        ),
        authenticationSessionResolver: sessionResolverFor(null),
      }),
    ).rejects.toThrow(new IdJagError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION));
  });

  // fail-closed: online RT は session resolver 無しでは検証できないので拒否する
  it('should reject an online refresh token when no session resolver is provided', async () => {
    await expect(
      resolveIdJagSubjectFromRefreshToken({
        refreshToken: 'rt-1',
        clientId: CLIENT_ID,
        refreshTokenResolver: refreshResolverFor(
          refreshTokenInfoFixture({ sessionId: 'session-1' }),
        ),
      }),
    ).rejects.toThrow(new IdJagError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION));
  });
});

describe('resolveIdJagActor', () => {
  // §9.7 の指針: actor は本 OP 発行・認証クライアント宛ての ID トークンに限る
  it('should return the actor sub from a valid ID Token', async () => {
    const actorIdToken = await mintIdToken({ sub: 'actor-1' });
    await expect(
      resolveIdJagActor({
        actorToken: actorIdToken,
        issuer: ISSUER,
        clientId: CLIENT_ID,
        jwks: idpKey.jwks,
      }),
    ).resolves.toEqual({ sub: 'actor-1' });
  });

  it('should reject an actor ID Token issued to another client with the fixed description', async () => {
    const foreignActorToken = await mintIdToken({ sub: 'actor-1', aud: 'another-client' });
    await expect(
      resolveIdJagActor({
        actorToken: foreignActorToken,
        issuer: ISSUER,
        clientId: CLIENT_ID,
        jwks: idpKey.jwks,
      }),
    ).rejects.toThrow(new IdJagError('invalid_request', ACTOR_TOKEN_INVALID_DESCRIPTION));
  });

  it('should reject a tampered actor token with the same fixed description', async () => {
    const actorIdToken = await mintIdToken({ sub: 'actor-1' });
    const [headerB64 = '', payloadB64 = ''] = actorIdToken.split('.');
    await expect(
      resolveIdJagActor({
        actorToken: `${headerB64}.${payloadB64}.AAAA`,
        issuer: ISSUER,
        clientId: CLIENT_ID,
        jwks: idpKey.jwks,
      }),
    ).rejects.toThrow(new IdJagError('invalid_request', ACTOR_TOKEN_INVALID_DESCRIPTION));
  });
});

describe('resolveIdJagActorFromCustomToken', () => {
  const CUSTOM_TYPE = 'urn:example:token-type:badge';

  // 責務分担の契約: リクエスト構造はライブラリ、トークン内容はリゾルバ
  it('should pass the token, type and client to the resolver and return its actor', async () => {
    const received: IdJagActorTokenResolverInput[] = [];
    await expect(
      resolveIdJagActorFromCustomToken({
        actorToken: 'opaque-actor-token',
        actorTokenType: CUSTOM_TYPE,
        clientId: CLIENT_ID,
        resolver: (input) => {
          received.push(input);
          return { sub: 'actor-1' };
        },
      }),
    ).resolves.toEqual({ sub: 'actor-1' });
    expect(received).toEqual([
      { actorToken: 'opaque-actor-token', actorTokenType: CUSTOM_TYPE, clientId: CLIENT_ID },
    ]);
  });

  // actor_token 自体が委譲済みのケース: リゾルバ経路はチェーン発行に対応する
  it('should preserve a nested act chain returned by the resolver', async () => {
    await expect(
      resolveIdJagActorFromCustomToken({
        actorToken: 'opaque-actor-token',
        actorTokenType: CUSTOM_TYPE,
        clientId: CLIENT_ID,
        resolver: () => ({ sub: 'actor-1', act: { sub: 'actor-0' } }),
      }),
    ).resolves.toEqual({ sub: 'actor-1', act: { sub: 'actor-0' } });
  });

  // draft §9.7 の開示最小化: act に載るのは sub と同形の act だけ
  it('should strip properties other than sub and act from the resolver result', async () => {
    const resolver: IdJagActorTokenResolver = () =>
      ({
        sub: 'actor-1',
        email: 'actor@example.com',
        act: { sub: 'actor-0', department: 'sales' },
      }) as unknown as IdJagActor;
    await expect(
      resolveIdJagActorFromCustomToken({
        actorToken: 'opaque-actor-token',
        actorTokenType: CUSTOM_TYPE,
        clientId: CLIENT_ID,
        resolver,
      }),
    ).resolves.toEqual({ sub: 'actor-1', act: { sub: 'actor-0' } });
  });

  it('should reject with the fixed description when the resolver returns null', async () => {
    await expect(
      resolveIdJagActorFromCustomToken({
        actorToken: 'opaque-actor-token',
        actorTokenType: CUSTOM_TYPE,
        clientId: CLIENT_ID,
        resolver: () => null,
      }),
    ).rejects.toThrow(new IdJagError('invalid_request', ACTOR_TOKEN_INVALID_DESCRIPTION));
  });

  // リゾルバが応答を明示したいときは IdJagError を投げる（そのまま透過する）
  it('should pass through an IdJagError thrown by the resolver', async () => {
    await expect(
      resolveIdJagActorFromCustomToken({
        actorToken: 'opaque-actor-token',
        actorTokenType: CUSTOM_TYPE,
        clientId: CLIENT_ID,
        resolver: () => {
          throw new IdJagError('invalid_request', 'The actor badge has been revoked');
        },
      }),
    ).rejects.toThrow(new IdJagError('invalid_request', 'The actor badge has been revoked'));
  });

  // リゾルバのバグ・依存障害はクライアント起因に見せない（server_error 経路）
  it('should propagate an unexpected resolver exception unchanged', async () => {
    await expect(
      resolveIdJagActorFromCustomToken({
        actorToken: 'opaque-actor-token',
        actorTokenType: CUSTOM_TYPE,
        clientId: CLIENT_ID,
        resolver: () => {
          throw new TypeError('store connection lost');
        },
      }),
    ).rejects.toThrow(new TypeError('store connection lost'));
  });

  it('should throw an Error when the resolver returns an actor with an empty sub', async () => {
    await expect(
      resolveIdJagActorFromCustomToken({
        actorToken: 'opaque-actor-token',
        actorTokenType: CUSTOM_TYPE,
        clientId: CLIENT_ID,
        resolver: () => ({ sub: '' }),
      }),
    ).rejects.toThrow(
      'The actorTokenResolver returned a malformed actor: sub must be a non-empty string at every level of the act chain',
    );
  });

  it('should throw an Error when a nested act level is missing its sub', async () => {
    const resolver: IdJagActorTokenResolver = () =>
      ({ sub: 'actor-1', act: { name: 'no-sub-here' } }) as unknown as IdJagActor;
    await expect(
      resolveIdJagActorFromCustomToken({
        actorToken: 'opaque-actor-token',
        actorTokenType: CUSTOM_TYPE,
        clientId: CLIENT_ID,
        resolver,
      }),
    ).rejects.toThrow(
      'The actorTokenResolver returned a malformed actor: sub must be a non-empty string at every level of the act chain',
    );
  });
});

describe('buildIdJagClaims with an actor', () => {
  // RFC 8693 §4.1 / draft §3.1: act は sub と別のクレームとして actor を記録する
  it('should embed the actor as the act claim', () => {
    const claims = buildIdJagClaims({
      issuer: ISSUER,
      subject: { sub: 'user-1' },
      audience: AUDIENCE,
      clientId: CLIENT_ID,
      scope: [],
      actor: { sub: 'actor-1' },
      lifetimeSeconds: 300,
      now: NOW,
    });
    expect(claims.sub).toBe('user-1');
    expect(claims.act).toEqual({ sub: 'actor-1' });
  });
});

describe('processIdJagIssuanceRequest with refresh token subjects and actors', () => {
  it('should issue an ID-JAG from a refresh token subject when the resolver is provided', async () => {
    const info = refreshTokenInfoFixture();
    const response = await processIdJagIssuanceRequest(
      issuanceContext({
        params: validParams({
          subject_token: 'rt-1',
          subject_token_type: TOKEN_TYPE_REFRESH_TOKEN,
        }),
        refreshTokenResolver: refreshResolverFor(info),
      }),
    );
    expect(response.token_type).toBe('N_A');
    const { payload } = decodeJwt(response.access_token);
    expect(payload).toMatchObject({
      iss: ISSUER,
      sub: 'user-1',
      aud: AUDIENCE,
      client_id: CLIENT_ID,
      auth_time: info.authTime,
      acr: 'urn:mace:incommon:iap:silver',
      amr: ['pwd', 'mfa'],
    });
  });

  // resolver 未注入の構成では refresh subject は従来どおり拒否される
  it('should reject a refresh token subject when no resolver is provided', async () => {
    await expect(
      processIdJagIssuanceRequest(
        issuanceContext({
          params: validParams({
            subject_token: 'rt-1',
            subject_token_type: TOKEN_TYPE_REFRESH_TOKEN,
          }),
        }),
      ),
    ).rejects.toThrow(
      new IdJagError(
        'invalid_request',
        `Unsupported subject_token_type for ID-JAG issuance. Only ${TOKEN_TYPE_ID_TOKEN} is supported.`,
      ),
    );
  });

  it('should embed the act claim when actor tokens are enabled', async () => {
    const actorIdToken = await mintIdToken({ sub: 'actor-1' });
    const response = await processIdJagIssuanceRequest(
      issuanceContext({
        allowActorTokens: true,
        params: validParams({
          actor_token: actorIdToken,
          actor_token_type: TOKEN_TYPE_ID_TOKEN,
        }),
      }),
    );
    const { payload } = decodeJwt(response.access_token);
    // RFC 8693 §4.1: sub は resource owner のまま、actor は act にだけ現れる
    expect(payload['sub']).toBe('user-1');
    expect(payload['act']).toEqual({ sub: 'actor-1' });
  });

  it('should reject an actor_token when actor tokens are not enabled', async () => {
    const actorIdToken = await mintIdToken({ sub: 'actor-1' });
    await expect(
      processIdJagIssuanceRequest(
        issuanceContext({
          params: validParams({
            actor_token: actorIdToken,
            actor_token_type: TOKEN_TYPE_ID_TOKEN,
          }),
        }),
      ),
    ).rejects.toThrow(
      new IdJagError('invalid_request', 'actor_token is not supported for ID-JAG issuance'),
    );
  });

  it('should reject an invalid actor token with the fixed actor description', async () => {
    await expect(
      processIdJagIssuanceRequest(
        issuanceContext({
          allowActorTokens: true,
          params: validParams({
            actor_token: 'not-a-jwt',
            actor_token_type: TOKEN_TYPE_ID_TOKEN,
          }),
        }),
      ),
    ).rejects.toThrow(new IdJagError('invalid_request', ACTOR_TOKEN_INVALID_DESCRIPTION));
  });

  it('should embed the act chain resolved by the custom actor token resolver', async () => {
    const response = await processIdJagIssuanceRequest(
      issuanceContext({
        allowActorTokens: true,
        actorTokenResolver: () => ({ sub: 'actor-1', act: { sub: 'actor-0' } }),
        params: validParams({
          actor_token: 'opaque-actor-token',
          actor_token_type: 'urn:example:token-type:badge',
        }),
      }),
    );
    const { payload } = decodeJwt(response.access_token);
    expect(payload['sub']).toBe('user-1');
    expect(payload['act']).toEqual({ sub: 'actor-1', act: { sub: 'actor-0' } });
  });

  // 組込み経路の非バイパス: id_token 種別はリゾルバ注入時も組込み検証で処理する
  it('should keep the built-in validation for id_token actors and never call the resolver', async () => {
    let resolverCalls = 0;
    await expect(
      processIdJagIssuanceRequest(
        issuanceContext({
          allowActorTokens: true,
          actorTokenResolver: () => {
            resolverCalls += 1;
            return { sub: 'resolver-must-not-decide-this' };
          },
          params: validParams({
            actor_token: 'not-a-jwt',
            actor_token_type: TOKEN_TYPE_ID_TOKEN,
          }),
        }),
      ),
    ).rejects.toThrow(new IdJagError('invalid_request', ACTOR_TOKEN_INVALID_DESCRIPTION));
    expect(resolverCalls).toBe(0);
  });

  it('should reject a custom actor_token_type when no resolver is configured', async () => {
    await expect(
      processIdJagIssuanceRequest(
        issuanceContext({
          allowActorTokens: true,
          params: validParams({
            actor_token: 'opaque-actor-token',
            actor_token_type: 'urn:example:token-type:badge',
          }),
        }),
      ),
    ).rejects.toThrow(
      new IdJagError(
        'invalid_request',
        `Unsupported actor_token_type for ID-JAG issuance. Only ${TOKEN_TYPE_ID_TOKEN} is supported.`,
      ),
    );
  });

  // allowActorTokens は親スイッチ: リゾルバを注入しても無効の間は受けない
  it('should reject actor tokens while disabled even when a resolver is configured', async () => {
    let resolverCalls = 0;
    await expect(
      processIdJagIssuanceRequest(
        issuanceContext({
          actorTokenResolver: () => {
            resolverCalls += 1;
            return { sub: 'actor-1' };
          },
          params: validParams({
            actor_token: 'opaque-actor-token',
            actor_token_type: 'urn:example:token-type:badge',
          }),
        }),
      ),
    ).rejects.toThrow(
      new IdJagError('invalid_request', 'actor_token is not supported for ID-JAG issuance'),
    );
    expect(resolverCalls).toBe(0);
  });
});
```

### redeem-id-jag.test.ts（受領側）

```typescript
import { beforeAll, describe, expect, it } from 'vitest';
import type { TokenClientInfo } from '@maronn-openid-connect/core';
import { ASSERTION_UNTRUSTED_DESCRIPTION, IdJagError } from './errors.js';
import { ID_JAG_JWT_TYP } from './issue-id-jag.js';
import {
  DEFAULT_ASSERTION_CLOCK_SKEW_SEC,
  JWT_BEARER_GRANT_TYPE,
  authorizeIdJagRedemptionClient,
  parseIdJagRedemptionParams,
  processIdJagRedemptionRequest,
  resolveIdJagGrantScope,
  verifyIdJagAssertion,
  type IdJagRedemptionContext,
  type IdJagTrustedIdentityProvider,
} from './redeem-id-jag.js';
import {
  generateTestRs256Key,
  signTestJwt,
  tamperSignature,
  type TestRs256Key,
} from './test-helpers.js';

/** 自 OP（リソース AS）の issuer。assertion の期待 aud。 */
const ISSUER = 'https://rs-as.example.net';
/** 信頼する IdP の issuer。assertion の iss。 */
const IDP_ISSUER = 'https://idp.example.com';
const CLIENT_ID = 'xaa-client';

/** 2026-01-01T00:00:00Z。Unix epoch 秒で 1767225600。 */
const NOW = new Date('2026-01-01T00:00:00Z');
const NOW_SECONDS = 1767225600;

let idpKey: TestRs256Key;
let otherKey: TestRs256Key;
let identityProviders: IdJagTrustedIdentityProvider[];

beforeAll(async () => {
  idpKey = await generateTestRs256Key('trusted-idp-key');
  otherKey = await generateTestRs256Key('untrusted-key');
  identityProviders = [{ issuer: IDP_ISSUER, jwks: idpKey.jwks }];
});

function idJagClaims(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    iss: IDP_ISSUER,
    sub: 'user-1',
    aud: ISSUER,
    client_id: CLIENT_ID,
    jti: 'jag-1',
    exp: NOW_SECONDS + 300,
    iat: NOW_SECONDS,
    scope: 'openid profile offline_access',
    ...overrides,
  };
}

function idJagHeader(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return { alg: 'RS256', typ: ID_JAG_JWT_TYP, kid: 'trusted-idp-key', ...overrides };
}

async function mintIdJag(options: {
  claims?: Record<string, unknown>;
  header?: Record<string, unknown>;
  key?: TestRs256Key;
} = {}): Promise<string> {
  const key = options.key ?? idpKey;
  return signTestJwt({
    header: idJagHeader(options.header),
    payload: idJagClaims(options.claims),
    privateKey: key.signingKey.privateKey,
  });
}

function confidentialClient(overrides: Partial<TokenClientInfo> = {}): TokenClientInfo {
  return {
    clientId: CLIENT_ID,
    clientSecret: 'secret',
    grantTypes: ['authorization_code', JWT_BEARER_GRANT_TYPE],
    tokenEndpointAuthMethod: 'client_secret_basic',
    ...overrides,
  };
}

function redemptionContext(
  assertion: string,
  overrides: Partial<IdJagRedemptionContext> = {},
): IdJagRedemptionContext {
  return {
    params: { grant_type: JWT_BEARER_GRANT_TYPE, assertion },
    client: confidentialClient(),
    issuer: ISSUER,
    identityProviders,
    configuredExpiresIn: 3600,
    now: NOW,
    ...overrides,
  };
}

async function expectAssertionRejection(
  assertion: string,
  description: string,
): Promise<void> {
  await expect(
    verifyIdJagAssertion({
      assertion,
      issuer: ISSUER,
      clientId: CLIENT_ID,
      identityProviders,
      now: NOW,
    }),
  ).rejects.toThrow(new IdJagError('invalid_grant', description));
}

describe('id-jag redemption constants', () => {
  // RFC 7523 §2.1
  it('should expose the jwt-bearer grant type URN', () => {
    expect(JWT_BEARER_GRANT_TYPE).toBe('urn:ietf:params:oauth:grant-type:jwt-bearer');
  });

  // RFC 8725 §3.8: leeway は数分以内。core の ID トークン検証と同じ 60 秒
  it('should default the clock skew tolerance to 60 seconds', () => {
    expect(DEFAULT_ASSERTION_CLOCK_SKEW_SEC).toBe(60);
  });
});

describe('authorizeIdJagRedemptionClient', () => {
  it('should accept a confidential client registered for the jwt-bearer grant', () => {
    expect(() => authorizeIdJagRedemptionClient(confidentialClient())).not.toThrow();
  });

  it('should reject a client not registered for the jwt-bearer grant with unauthorized_client', () => {
    const client = confidentialClient({ grantTypes: ['authorization_code'] });
    expect(() => authorizeIdJagRedemptionClient(client)).toThrow(
      new IdJagError(
        'unauthorized_client',
        'The client is not authorized to use the jwt-bearer grant type',
      ),
    );
  });

  // draft §9.1: confidential client 限定
  it('should reject a public client with unauthorized_client', () => {
    const client = confidentialClient({
      tokenEndpointAuthMethod: 'none',
      clientSecret: undefined,
    });
    expect(() => authorizeIdJagRedemptionClient(client)).toThrow(
      new IdJagError(
        'unauthorized_client',
        'Public clients are not allowed to use the jwt-bearer grant type',
      ),
    );
  });
});

describe('parseIdJagRedemptionParams', () => {
  it('should return the typed parameters', () => {
    expect(
      parseIdJagRedemptionParams({
        grant_type: JWT_BEARER_GRANT_TYPE,
        assertion: 'a.b.c',
        scope: 'openid',
      }),
    ).toEqual({ assertion: 'a.b.c', scope: 'openid' });
  });

  it('should reject a missing assertion with invalid_request', () => {
    expect(() => parseIdJagRedemptionParams({ grant_type: JWT_BEARER_GRANT_TYPE })).toThrow(
      new IdJagError('invalid_request', 'assertion is required'),
    );
  });

  // 非目標: RAR
  it('should reject authorization_details with invalid_request', () => {
    expect(() =>
      parseIdJagRedemptionParams({
        grant_type: JWT_BEARER_GRANT_TYPE,
        assertion: 'a.b.c',
        authorization_details: '[{"type":"x"}]',
      }),
    ).toThrow(
      new IdJagError(
        'invalid_request',
        'authorization_details is not supported for the jwt-bearer grant',
      ),
    );
  });
});

describe('verifyIdJagAssertion', () => {
  describe('acceptance', () => {
    it('should return the payload of a valid ID-JAG', async () => {
      const assertion = await mintIdJag({
        claims: {
          resource: 'https://api.example.net/files',
          auth_time: NOW_SECONDS - 60,
          acr: 'silver',
          amr: ['pwd'],
        },
      });
      await expect(
        verifyIdJagAssertion({
          assertion,
          issuer: ISSUER,
          clientId: CLIENT_ID,
          identityProviders,
          now: NOW,
        }),
      ).resolves.toEqual({
        iss: IDP_ISSUER,
        sub: 'user-1',
        aud: ISSUER,
        client_id: CLIENT_ID,
        jti: 'jag-1',
        exp: NOW_SECONDS + 300,
        iat: NOW_SECONDS,
        scope: 'openid profile offline_access',
        resource: 'https://api.example.net/files',
        auth_time: NOW_SECONDS - 60,
        acr: 'silver',
        amr: ['pwd'],
      });
    });

    // draft §4.4.1: aud は要素数 1 の配列でもよい
    it('should accept an aud claim that is a single-element array', async () => {
      const assertion = await mintIdJag({ claims: { aud: [ISSUER] } });
      await expect(
        verifyIdJagAssertion({
          assertion,
          issuer: ISSUER,
          clientId: CLIENT_ID,
          identityProviders,
          now: NOW,
        }),
      ).resolves.toMatchObject({ aud: [ISSUER] });
    });

    // RFC 7515 §4.1.9: typ は application/ 前置と大文字小文字の差を許容する
    it('should accept an application/-prefixed typ header', async () => {
      const assertion = await mintIdJag({ header: { typ: `application/${ID_JAG_JWT_TYP}` } });
      await expect(
        verifyIdJagAssertion({
          assertion,
          issuer: ISSUER,
          clientId: CLIENT_ID,
          identityProviders,
          now: NOW,
        }),
      ).resolves.toMatchObject({ jti: 'jag-1' });
    });

    // kid が無くても alg 一致の鍵で検証できる
    it('should verify with an alg-matched key when the header has no kid', async () => {
      const assertion = await mintIdJag({ header: { kid: undefined } });
      await expect(
        verifyIdJagAssertion({
          assertion,
          issuer: ISSUER,
          clientId: CLIENT_ID,
          identityProviders,
          now: NOW,
        }),
      ).resolves.toMatchObject({ sub: 'user-1' });
    });

    it('should pick the trusted IdP by the iss claim when several are configured', async () => {
      const assertion = await mintIdJag();
      await expect(
        verifyIdJagAssertion({
          assertion,
          issuer: ISSUER,
          clientId: CLIENT_ID,
          identityProviders: [
            { issuer: 'https://another-idp.example.org', jwks: otherKey.jwks },
            { issuer: IDP_ISSUER, jwks: idpKey.jwks },
          ],
          now: NOW,
        }),
      ).resolves.toMatchObject({ iss: IDP_ISSUER });
    });

    // RFC 8725 §3.8: exp は leeway 内なら許容
    it('should accept an assertion that expired within the clock skew tolerance', async () => {
      const assertion = await mintIdJag({ claims: { exp: NOW_SECONDS - 30 } });
      await expect(
        verifyIdJagAssertion({
          assertion,
          issuer: ISSUER,
          clientId: CLIENT_ID,
          identityProviders,
          now: NOW,
        }),
      ).resolves.toMatchObject({ exp: NOW_SECONDS - 30 });
    });
  });

  describe('structural rejection', () => {
    it('should reject a value that is not a compact JWS', async () => {
      await expectAssertionRejection(
        'not-a-jwt',
        'The provided assertion is not a valid JWS compact serialization',
      );
    });

    it('should reject a JWS whose segments are not base64url JSON', async () => {
      await expectAssertionRejection(
        '!!!.???.___',
        'The provided assertion is not a valid JWS compact serialization',
      );
    });

    // draft §4.4.1 / RFC 8725 §3.11: typ の検証で token confusion を拒否する
    it('should reject a JWT typ other than oauth-id-jag+jwt', async () => {
      const assertion = await mintIdJag({ header: { typ: 'JWT' } });
      await expectAssertionRejection(assertion, `The assertion typ must be ${ID_JAG_JWT_TYP}`);
    });

    it('should reject a missing typ header', async () => {
      const assertion = await mintIdJag({ header: { typ: undefined } });
      await expectAssertionRejection(assertion, `The assertion typ must be ${ID_JAG_JWT_TYP}`);
    });

    it('should reject alg none', async () => {
      const assertion = await mintIdJag({ header: { alg: 'none' } });
      await expectAssertionRejection(assertion, 'The assertion alg is missing or "none"');
    });

    // RFC 8725 §3.1: 外部鍵取得ヘッダは SSRF と鍵差し替えの経路になるため拒否する
    it('should reject a jku header', async () => {
      const assertion = await mintIdJag({ header: { jku: 'https://evil.example.com/jwks' } });
      await expectAssertionRejection(
        assertion,
        'The assertion JOSE header contains unsupported field: jku',
      );
    });

    it('should reject an embedded jwk header', async () => {
      const assertion = await mintIdJag({ header: { jwk: { kty: 'RSA' } } });
      await expectAssertionRejection(
        assertion,
        'The assertion JOSE header contains unsupported field: jwk',
      );
    });
  });

  describe('issuer and signature rejection', () => {
    // オラクル排除: iss 非信頼と署名不正は同一文言
    it('should reject an untrusted issuer with the fixed description', async () => {
      const assertion = await mintIdJag({ claims: { iss: 'https://unknown-idp.example.org' } });
      await expectAssertionRejection(assertion, ASSERTION_UNTRUSTED_DESCRIPTION);
    });

    it('should reject a tampered signature with the same fixed description', async () => {
      const assertion = tamperSignature(await mintIdJag());
      await expectAssertionRejection(assertion, ASSERTION_UNTRUSTED_DESCRIPTION);
    });

    it('should reject a signature by an untrusted key with the same fixed description', async () => {
      const assertion = await mintIdJag({ key: otherKey, header: { kid: 'untrusted-key' } });
      await expectAssertionRejection(assertion, ASSERTION_UNTRUSTED_DESCRIPTION);
    });

    // draft §9.3: 自分が発行した ID-JAG は同一ドメイン内で引き換えない
    it('should reject an assertion issued by this authorization server itself', async () => {
      const assertion = await mintIdJag({ claims: { iss: ISSUER } });
      await expectAssertionRejection(
        assertion,
        'An assertion issued by this authorization server cannot be redeemed here',
      );
    });

    it('should reject the self-issued assertion even when the own issuer is trust-listed', async () => {
      const assertion = await mintIdJag({ claims: { iss: ISSUER } });
      await expect(
        verifyIdJagAssertion({
          assertion,
          issuer: ISSUER,
          clientId: CLIENT_ID,
          identityProviders: [{ issuer: ISSUER, jwks: idpKey.jwks }],
          now: NOW,
        }),
      ).rejects.toThrow(
        new IdJagError(
          'invalid_grant',
          'An assertion issued by this authorization server cannot be redeemed here',
        ),
      );
    });
  });

  describe('claim rejection', () => {
    // draft §4.4.1: aud 不一致は audience injection として拒否
    it('should reject an aud claim for another authorization server', async () => {
      const assertion = await mintIdJag({ claims: { aud: 'https://other-as.example.org' } });
      await expectAssertionRejection(
        assertion,
        'The assertion audience does not match this authorization server',
      );
    });

    // draft §4.4.1: 配列 aud は要素数 1 のみ
    it('should reject an aud array with more than one element', async () => {
      const assertion = await mintIdJag({
        claims: { aud: [ISSUER, 'https://other-as.example.org'] },
      });
      await expectAssertionRejection(
        assertion,
        'The assertion audience does not match this authorization server',
      );
    });

    it('should reject an expired assertion', async () => {
      const assertion = await mintIdJag({ claims: { exp: NOW_SECONDS - 120 } });
      await expectAssertionRejection(assertion, 'The assertion has expired');
    });

    it('should reject a missing exp claim', async () => {
      const assertion = await mintIdJag({ claims: { exp: undefined } });
      await expectAssertionRejection(assertion, 'The assertion is missing an exp claim');
    });

    it('should reject an iat claim in the future', async () => {
      const assertion = await mintIdJag({ claims: { iat: NOW_SECONDS + 120 } });
      await expectAssertionRejection(assertion, 'The assertion iat is in the future');
    });

    it('should reject a missing iat claim', async () => {
      const assertion = await mintIdJag({ claims: { iat: undefined } });
      await expectAssertionRejection(assertion, 'The assertion is missing an iat claim');
    });

    it('should reject an nbf claim that has not arrived yet', async () => {
      const assertion = await mintIdJag({ claims: { nbf: NOW_SECONDS + 120 } });
      await expectAssertionRejection(assertion, 'The assertion is not yet valid');
    });

    // draft §3.1: jti は REQUIRED
    it('should reject a missing jti claim', async () => {
      const assertion = await mintIdJag({ claims: { jti: undefined } });
      await expectAssertionRejection(assertion, 'The assertion is missing a jti claim');
    });

    it('should reject a missing sub claim', async () => {
      const assertion = await mintIdJag({ claims: { sub: undefined } });
      await expectAssertionRejection(assertion, 'The assertion is missing a sub claim');
    });

    it('should reject a missing client_id claim', async () => {
      const assertion = await mintIdJag({ claims: { client_id: undefined } });
      await expectAssertionRejection(assertion, 'The assertion is missing a client_id claim');
    });

    // draft §4.4.1: client_id はリクエストを認証したクライアントと一致しなければならない
    it('should reject a client_id claim bound to another client', async () => {
      const assertion = await mintIdJag({ claims: { client_id: 'another-client' } });
      await expectAssertionRejection(
        assertion,
        'The assertion client_id does not match the authenticated client',
      );
    });

    it('should reject a non-string scope claim', async () => {
      const assertion = await mintIdJag({ claims: { scope: ['openid'] } });
      await expectAssertionRejection(assertion, 'The assertion scope claim must be a string');
    });

    it('should reject a resource claim that is neither a string nor a string array', async () => {
      const assertion = await mintIdJag({ claims: { resource: 42 } });
      await expectAssertionRejection(
        assertion,
        'The assertion resource claim must be a string or an array of strings',
      );
    });
  });
});

describe('resolveIdJagGrantScope', () => {
  it('should inherit the assertion scope when no scope is requested', () => {
    expect(resolveIdJagGrantScope(undefined, 'openid profile')).toEqual(['openid', 'profile']);
  });

  // draft §4.4.3 SHOULD NOT: refresh token を発行しないため offline_access は常に落とす
  it('should always drop offline_access from the assertion scope', () => {
    expect(resolveIdJagGrantScope(undefined, 'openid offline_access profile')).toEqual([
      'openid',
      'profile',
    ]);
  });

  it('should narrow to the requested subset', () => {
    expect(resolveIdJagGrantScope('openid', 'openid profile')).toEqual(['openid']);
  });

  it('should return an empty scope when the assertion carries none', () => {
    expect(resolveIdJagGrantScope(undefined, undefined)).toEqual([]);
  });

  it('should reject a requested scope beyond the assertion scope with invalid_scope', () => {
    expect(() => resolveIdJagGrantScope('openid email', 'openid profile')).toThrow(
      new IdJagError('invalid_scope', 'The requested scope exceeds the scope of the assertion'),
    );
  });

  // offline_access は除去済みの集合が上限になるため、要求しても超過扱いになる
  it('should reject a requested offline_access with invalid_scope', () => {
    expect(() => resolveIdJagGrantScope('offline_access', 'openid offline_access')).toThrow(
      new IdJagError('invalid_scope', 'The requested scope exceeds the scope of the assertion'),
    );
  });
});

describe('processIdJagRedemptionRequest', () => {
  it('should derive the grant material from a valid assertion', async () => {
    const assertion = await mintIdJag({
      claims: { resource: 'https://api.example.net/files', auth_time: NOW_SECONDS - 60 },
    });
    await expect(processIdJagRedemptionRequest(redemptionContext(assertion))).resolves.toEqual({
      subject: 'user-1',
      clientId: CLIENT_ID,
      scope: ['openid', 'profile'],
      requestedResources: ['https://api.example.net/files'],
      expiresIn: 3600,
      idpIssuer: IDP_ISSUER,
      jti: 'jag-1',
      authTime: NOW_SECONDS - 60,
    });
  });

  it('should narrow the scope to the requested subset', async () => {
    const assertion = await mintIdJag();
    await expect(
      processIdJagRedemptionRequest(
        redemptionContext(assertion, {
          params: { grant_type: JWT_BEARER_GRANT_TYPE, assertion, scope: 'openid' },
        }),
      ),
    ).resolves.toMatchObject({ scope: ['openid'] });
  });

  it('should reject an unauthorized client before validating the assertion', async () => {
    await expect(
      processIdJagRedemptionRequest(
        redemptionContext('never-validated', {
          client: confidentialClient({ grantTypes: ['authorization_code'] }),
        }),
      ),
    ).rejects.toThrow(
      new IdJagError(
        'unauthorized_client',
        'The client is not authorized to use the jwt-bearer grant type',
      ),
    );
  });

  it('should reject an assertion bound to another client with invalid_grant', async () => {
    const assertion = await mintIdJag({ claims: { client_id: 'another-client' } });
    await expect(processIdJagRedemptionRequest(redemptionContext(assertion))).rejects.toThrow(
      new IdJagError(
        'invalid_grant',
        'The assertion client_id does not match the authenticated client',
      ),
    );
  });

  it('should reject every assertion when no identity provider is trusted', async () => {
    const assertion = await mintIdJag();
    await expect(
      processIdJagRedemptionRequest(redemptionContext(assertion, { identityProviders: [] })),
    ).rejects.toThrow(new IdJagError('invalid_grant', ASSERTION_UNTRUSTED_DESCRIPTION));
  });

  it('should reject a non-positive configuredExpiresIn with a RangeError', async () => {
    const assertion = await mintIdJag();
    await expect(
      processIdJagRedemptionRequest(redemptionContext(assertion, { configuredExpiresIn: 0 })),
    ).rejects.toThrow(RangeError);
  });

  // draft §4.4.3: 同じ ID-JAG は有効期間内なら再提示できる（リプレイ拒否ストアを持たない）
  it('should accept the same assertion presented twice', async () => {
    const assertion = await mintIdJag();
    const first = await processIdJagRedemptionRequest(redemptionContext(assertion));
    const second = await processIdJagRedemptionRequest(redemptionContext(assertion));
    expect(first).toEqual(second);
  });
});

describe('verifyIdJagAssertion with an act claim', () => {
  // draft §3.1 OPTIONAL / RFC 8693 §4.1: act は検証して素通しする（黙って落とさない）
  it('should return the act claim of an actor-bearing ID-JAG', async () => {
    const assertion = await mintIdJag({ claims: { act: { sub: 'actor-1' } } });
    await expect(
      verifyIdJagAssertion({
        assertion,
        issuer: ISSUER,
        clientId: CLIENT_ID,
        identityProviders,
        now: NOW,
      }),
    ).resolves.toMatchObject({ act: { sub: 'actor-1' } });
  });

  // RFC 8693 §4.1: ネストした act はより古い actor のチェーンを表す
  it('should accept a nested act chain', async () => {
    const assertion = await mintIdJag({
      claims: { act: { sub: 'actor-1', act: { sub: 'actor-0' } } },
    });
    await expect(
      verifyIdJagAssertion({
        assertion,
        issuer: ISSUER,
        clientId: CLIENT_ID,
        identityProviders,
        now: NOW,
      }),
    ).resolves.toMatchObject({ act: { sub: 'actor-1', act: { sub: 'actor-0' } } });
  });

  it('should reject a non-object act claim', async () => {
    const assertion = await mintIdJag({ claims: { act: 'actor-1' } });
    await expectAssertionRejection(assertion, 'The assertion act claim is malformed');
  });

  it('should reject an act claim without a sub', async () => {
    const assertion = await mintIdJag({ claims: { act: { role: 'admin' } } });
    await expectAssertionRejection(assertion, 'The assertion act claim is malformed');
  });

  it('should reject an act claim with a malformed nested chain', async () => {
    const assertion = await mintIdJag({ claims: { act: { sub: 'actor-1', act: { sub: 42 } } } });
    await expectAssertionRejection(assertion, 'The assertion act claim is malformed');
  });
});

describe('processIdJagRedemptionRequest with an act claim', () => {
  // 生成コードが act をアクセストークンへ引き継げるよう、grant 素材に含める
  it('should propagate the act claim into the grant material', async () => {
    const assertion = await mintIdJag({ claims: { act: { sub: 'actor-1' } } });
    await expect(processIdJagRedemptionRequest(redemptionContext(assertion))).resolves.toMatchObject(
      {
        subject: 'user-1',
        actor: { sub: 'actor-1' },
      },
    );
  });

  it('should leave the actor undefined for an act-less ID-JAG', async () => {
    const assertion = await mintIdJag();
    const grant = await processIdJagRedemptionRequest(redemptionContext(assertion));
    expect('actor' in grant).toBe(false);
  });
});
```

### テストが全部通ると何が保証されるのか

- **プロトコル形状**: 発行応答の `token_type: N_A` と `issued_token_type`、ID-JAG の JOSE ヘッダー（RS256 / `oauth-id-jag+jwt` / kid）と draft §3.1 のクレーム一式、scope 無し発行で scope クレーム自体が消えること
- **クロスドメイン境界**: 自 issuer 宛ての発行と自己発行 assertion の redemption が、許可リストや信頼リストの内容にかかわらず拒否されること
- **束縛**: 他クライアント宛て ID トークンでの発行、他クライアントの ID-JAG の redemption、public client と grant 未登録クライアントがすべて拒否されること
- **オラクル排除**: subject_token の失敗種別、および iss 非信頼と署名不正が、それぞれ同一応答になること
- **リプレイの設計**: 同じ ID-JAG の再提示が成功すること（draft §4.4.3 の契約)と、期限切れが leeway を超えたら拒否されること
- **refresh token subject**: RT の grant 文脈から subject が組み立つこと、rotation 済み RT の再提示が family 失効を発火させて拒否されること、online RT がセッション終了後に使えないこと、`openid` の無い grant の RT が拒否されること、RT が消費されないこと（同じ RT で 2 回発行できる）
- **actor**: 無効時（既定）の存在拒否、有効時の対応規則と actor 検証（他クライアント宛て・改ざんの固定文言拒否）、`act` の内容（actor の sub のみ）、受領側の `act` 構造検証（ネスト受理、malformed 拒否）と発行素材への伝播
- **actor リゾルバ**: リゾルバ未設定時の独自種別拒否、設定時の受理（入力の固定検証とネストチェーンの発行）、戻り値の正規化（余分な属性の除去）、`null` の固定文言拒否、`IdJagError` と他例外の透過、malformed 戻り値の Error、id_token 種別と `allowActorTokens` 無効時にリゾルバが呼ばれないこと

## CLI 統合と生成コードへの寄与

`--enable id-jag` は新しいエンドポイントを増やさない。
トークンルートへの 2 分岐、設定オブジェクト、discovery のメタデータ、conformance テストが条件付き補間で加わるだけで、フラグなし生成の出力は従来とバイト単位で同一である（CLI のテストが「無効時の全ファイルに id-jag への言及が無いこと」を固定している）。
以下はすべて hono ターゲットの生成結果からの掲載で、他フレームワークは同じテンプレートの変換共有により同等になる。

### config.ts に入るもの

サンプルクライアントの `grantTypes` に両 URN が加わる。

```typescript
      // EXPERIMENTAL (ID-JAG draft §4.3 / §4.4): the token-exchange URN lets this
      // confidential client request an ID-JAG for a trusted resource authorization
      // server, and the jwt-bearer URN lets it redeem an ID-JAG issued by a trusted
      // identity provider. Remove either to forbid that half of Cross-App Access.
      grantTypes: ['authorization_code', 'refresh_token', 'urn:ietf:params:oauth:grant-type:token-exchange', 'urn:ietf:params:oauth:grant-type:jwt-bearer'],
```

### routes/discovery.ts に入るもの

`grant_types_supported` に両 URN が入り（token-exchange 機能が無効でも Token Exchange URN は発行側の広告として入る）、draft §7 の 2 つのメタデータが応答へマージされる。
信頼 IdP や許可 audience の内容は出さない（draft §9.4 MUST NOT）。

```typescript
    grantTypesSupported: ['authorization_code', 'refresh_token', 'urn:ietf:params:oauth:grant-type:token-exchange', 'urn:ietf:params:oauth:grant-type:jwt-bearer', 'urn:ietf:params:oauth:grant-type:device_code'],
```

```typescript
    // EXPERIMENTAL — ID-JAG draft §7.1: this OP can issue an ID-JAG via token
    // exchange (identity-chaining requested token type).
    identity_chaining_requested_token_types_supported: ['urn:ietf:params:oauth:token-type:id-jag'],
    // EXPERIMENTAL — ID-JAG draft §7.2: this OP can process the ID-JAG grant
    // profile on the jwt-bearer grant. Which issuers are actually trusted is
    // local policy and is not disclosed here (draft §9.4).
    authorization_grant_profiles_supported: ['urn:ietf:params:oauth:grant-profile:id-jag'],
```

### routes/token.ts に入るもの

まず import と、設定オブジェクトおよび信頼 IdP の JWKS 解決ヘルパが入る。
`jwksUri` の fetch 先は静的設定からしか来ない。fetch の失敗は `invalid_grant` にせず 500 に流す（assertion を評価していないのに、こちら側の障害でクライアントの grant を不正扱いしないため）。

```typescript
import {
  IdJagError,
  JWT_BEARER_GRANT_TYPE,
  matchesIdJagIssuanceRequest,
  processIdJagIssuanceRequest,
  processIdJagRedemptionRequest,
  type IdJagAccessTokenInfo,
  type IdJagActorTokenResolver,
  type IdJagTrustedIdentityProvider,
} from '@maronn-openid-connect/experimental/id-jag';
import type { JwkSet } from '@maronn-openid-connect/core';
```

```typescript
/**
 * EXPERIMENTAL — Cross-App Access (XAA) / ID-JAG settings
 * (draft-ietf-oauth-identity-assertion-authz-grant-04).
 *
 * Issuing side (this OP as the IdP, draft §4.3):
 * - allowedAudiences: resource authorization server issuers this IdP may issue
 *   an ID-JAG for. Empty by default (fail safe): every issuance request is
 *   rejected with invalid_target until you list the peer AS issuers here.
 *   Adding an entry grants that cross-app connection on behalf of every user —
 *   there is no per-user consent screen in this flow.
 * - idJagLifetimeSeconds: ID-JAG lifetime. Keep it short (draft example: 300);
 *   clients are expected to request a fresh one instead of holding it.
 * - allowedScopes: optional cap on the scopes an ID-JAG may carry. undefined
 *   passes the requested scopes through (the resource AS applies its own
 *   policy again on redemption).
 * - allowRefreshTokenSubjects: whether a refresh token this OP issued may stand
 *   in for the ID Token as the subject_token (draft §4.3 MAY), so a client can
 *   request a fresh ID-JAG after its ID Token expired without a new SSO round
 *   trip. Validated exactly like the standard refresh_token grant (rotation
 *   reuse revokes the token family; online tokens require the login session to
 *   be alive); the refresh token is NOT consumed. Grants without the openid
 *   scope are refused — their refresh token replaces no identity assertion.
 * - allowActorTokens: whether an actor_token (identifying who acts on the
 *   subject's behalf) is accepted and recorded as the ID-JAG's act claim
 *   (RFC 8693 §4.1). The draft defines no normative actor processing (§9.7
 *   sketches extensions), so this is an opt-in extension and defaults to
 *   false — an actor_token is rejected until you flip it, whatever else is
 *   configured. An actor_token_type of id_token always goes through the
 *   built-in validation (an ID Token this OP issued to the authenticated
 *   client).
 * - actorTokenResolver: hook for actor_token types OTHER than id_token
 *   (RFC 8693 allows any token type identifier). The library validates the
 *   request structure and the shape of what you return; validating the token
 *   CONTENT (signature, revocation, whose token it is) is entirely this
 *   function's job. Return the act value ({ sub, act? }) for a valid token,
 *   null for an invalid one (answered with a fixed invalid_request), or throw
 *   IdJagError to pick the response yourself. It cannot replace the built-in
 *   id_token validation, and it is never called while allowActorTokens is
 *   false.
 *
 * Consuming side (this OP as the resource authorization server, draft §4.4):
 * - trustedIdentityProviders: the IdPs whose ID-JAGs are accepted on the
 *   jwt-bearer grant. Empty by default (fail safe). Keys come from the inline
 *   `jwks` when present, otherwise from `jwksUri` (fetched and cached below).
 *   Never derive the key source from the assertion itself.
 */
export const idJagConfig = {
  allowedAudiences: [] as string[],
  idJagLifetimeSeconds: 300,
  allowedScopes: undefined as string[] | undefined,
  allowRefreshTokenSubjects: true,
  allowActorTokens: false,
  actorTokenResolver: undefined as IdJagActorTokenResolver | undefined,
  trustedIdentityProviders: [] as Array<{ issuer: string; jwksUri?: string; jwks?: JwkSet }>,
};

/**
 * EXPERIMENTAL — jwks_uri cache for trusted identity providers.
 *
 * A fetched JWKS is reused for 300 seconds, so a signing-key rotation at the
 * IdP can take up to that long to be picked up (a verification that fails
 * within the window is answered as an untrusted assertion). The fetch target
 * comes exclusively from the static idJagConfig above — never from request or
 * assertion content — which is what keeps this endpoint SSRF-free.
 */
const idJagJwksCache = new Map<string, { jwks: JwkSet; expiresAt: number }>();
const ID_JAG_JWKS_CACHE_TTL_MS = 300_000;

async function resolveTrustedIdentityProviders(): Promise<IdJagTrustedIdentityProvider[]> {
  const resolved: IdJagTrustedIdentityProvider[] = [];
  for (const entry of idJagConfig.trustedIdentityProviders) {
    if (entry.jwks !== undefined) {
      resolved.push({ issuer: entry.issuer, jwks: entry.jwks });
      continue;
    }
    if (entry.jwksUri === undefined) {
      // An entry with neither jwks nor jwksUri can never verify anything; skip
      // it so the assertion is answered with the fixed untrusted description.
      continue;
    }
    const cached = idJagJwksCache.get(entry.jwksUri);
    if (cached !== undefined && cached.expiresAt > Date.now()) {
      resolved.push({ issuer: entry.issuer, jwks: cached.jwks });
      continue;
    }
    // A failed fetch propagates: the generic catch turns it into server_error,
    // which is honest — the assertion was never evaluated, so invalid_grant
    // would wrongly blame the client for an outage on this side.
    const response = await fetch(entry.jwksUri);
    if (!response.ok) {
      throw new Error(`Fetching the JWKS of trusted IdP ${entry.issuer} failed with status ${response.status}`);
    }
    const jwks = (await response.json()) as JwkSet;
    idJagJwksCache.set(entry.jwksUri, { jwks, expiresAt: Date.now() + ID_JAG_JWKS_CACHE_TTL_MS });
    resolved.push({ issuer: entry.issuer, jwks });
  }
  return resolved;
}
```

ハンドラ内では、クライアント認証の直後、core の `validateGrantTypeSupported` より前に発行分岐が入る。
既存 token-exchange 分岐と grant_type URN を共有するため、必ずそれより前に置かれる。

```typescript
    // --- EXPERIMENTAL: ID-JAG issuance (Cross-App Access, draft §4.3) ------
    // A token-exchange request whose requested_token_type is the ID-JAG URN.
    // Dispatched right after client authentication and BEFORE the plain
    // token-exchange branch (same grant_type URN) and core's
    // validateGrantTypeSupported. The subject_token must be an ID Token this OP
    // issued to the authenticated client; the result is a signed grant JWT for
    // the resource authorization server named by `audience` — not an access
    // token (the response carries token_type N_A).
    //
    // Backed by @maronn-openid-connect/experimental, whose API is NOT stable: it may change
    // in a breaking way between releases. The underlying specification is an
    // IETF draft (-04) and may itself change. Do not build production code on
    // this without pinning versions.
    if (matchesIdJagIssuanceRequest(params)) {
      const idJagIssuanceConfig = c.get('config');
      // The ID-JAG is signed with a registered RS256 key so the peer AS can
      // verify it against this OP's JWKS endpoint (same key-selection contract
      // as JARM: RS256 is pinned, the active key may be a different alg).
      const idJagSigningKeys = (c.get('signingKeys') as SigningKey[] | undefined) ?? [];
      let idJagSigningKey: SigningKey;
      try {
        idJagSigningKey = selectSigningKeyByAlg(idJagSigningKeys, 'RS256');
      } catch {
        c.header('Cache-Control', 'no-store');
        c.header('Pragma', 'no-cache');
        return c.json(
          { error: 'server_error', error_description: 'No RS256 signing key registered for ID-JAG issuance' },
          500,
        );
      }
      // The subject_token is verified against the same JWKS that id_token_hint
      // uses (the OP's own ID Token signing keys) — draft §4.3.3 requires the
      // assertion's audience to be the authenticated client, which
      // processIdJagIssuanceRequest checks.
      const idJagJwks = await c.get('jwksProvider')();

      const idJagIssuanceResponse = await processIdJagIssuanceRequest({
        params,
        client: tokenClient,
        issuer: idJagIssuanceConfig.issuer,
        jwks: idJagJwks,
        signingKey: idJagSigningKey,
        allowedAudiences: idJagConfig.allowedAudiences,
        allowedScopes: idJagConfig.allowedScopes,
        lifetimeSeconds: idJagConfig.idJagLifetimeSeconds,
        // Extension (draft §9.7): when enabled, an actor_token is recorded as
        // the ID-JAG's act claim. id_token actors get the same built-in
        // validation as the subject; other types go to the deployment's
        // resolver (content validation is the resolver's responsibility).
        allowActorTokens: idJagConfig.allowActorTokens,
        ...(idJagConfig.actorTokenResolver === undefined
          ? {}
          : { actorTokenResolver: idJagConfig.actorTokenResolver }),
        ...(idJagConfig.allowRefreshTokenSubjects
          ? { refreshTokenResolver, authenticationSessionResolver }
          : {}),
      });

      // RFC 6749 §5.1: token responses MUST NOT be cached. The ID-JAG itself is
      // not persisted — it is a self-contained signed grant the peer AS
      // verifies by signature and exp.
      c.header('Cache-Control', 'no-store');
      c.header('Pragma', 'no-cache');
      return c.json(idJagIssuanceResponse);
    }
```

続いて受領分岐が入る。アクセストークンの発行と保存は既存トークンルートと同じ core の部品（`buildAccessTokenAudience` / `buildAccessTokenPayload` / issuer / store）で行い、`id_token` と `refresh_token` は返さない。
redemption ごとに独立した grant として扱うため、`grantId` にはそのトークン自身の `jti` を使う（同じ ID-JAG からの別の redemption を巻き込み失効させないため）。

```typescript
    // --- EXPERIMENTAL: ID-JAG redemption (Cross-App Access, draft §4.4) ----
    // The jwt-bearer grant (RFC 7523 §2.1). The assertion must be an ID-JAG
    // (typ oauth-id-jag+jwt) issued by one of idJagConfig.trustedIdentityProviders
    // for THIS issuer and for the authenticated client. This OP then issues its
    // own access token — the IdP never mints tokens for this AS.
    //
    // No ID Token is issued (this is not an OIDC authentication flow: the
    // openid scope only grants UserInfo access) and no refresh token is issued
    // (draft §4.4.3 SHOULD NOT — re-presenting the still-valid ID-JAG replaces
    // the refresh token).
    if (params.grant_type === JWT_BEARER_GRANT_TYPE) {
      const idJagRedemptionConfig = c.get('config');
      const idJagIdentityProviders = await resolveTrustedIdentityProviders();

      const idJagGrant = await processIdJagRedemptionRequest({
        params,
        client: tokenClient,
        issuer: idJagRedemptionConfig.issuer,
        identityProviders: idJagIdentityProviders,
        configuredExpiresIn: idJagRedemptionConfig.accessTokenExpiresIn,
      });

      // config / privateKey / keyId are bound further down for the standard
      // grants. This branch reads them on its own so the generated output is
      // unchanged when the feature is off; it returns, so nothing runs twice.
      const idJagTokenIssuer: AccessTokenIssuer =
        idJagRedemptionConfig.accessTokenFormat === 'opaque'
          ? createOpaqueAccessTokenIssuer()
          : createJwtAccessTokenIssuer();

      // Same aud policy as the standard token route: the UserInfo endpoint
      // stays a permanent member (RFC 9068 §3); the ID-JAG's resource claim
      // (RFC 8707) contributes the requested resources.
      const idJagAudience = buildAccessTokenAudience({
        userInfoEndpoint: `${idJagRedemptionConfig.issuer}/userinfo`,
        requested: idJagGrant.requestedResources,
        issuer: idJagRedemptionConfig.issuer,
      });

      const idJagIssuedAt = Math.floor(Date.now() / 1000);
      const idJagAccessTokenPayload = buildAccessTokenPayload({
        issuer: idJagRedemptionConfig.issuer,
        subject: idJagGrant.subject,
        clientId: idJagGrant.clientId,
        scope: idJagGrant.scope,
        audience: idJagAudience,
        expiresIn: idJagGrant.expiresIn,
        issuedAt: idJagIssuedAt,
      });
      const idJagAccessToken = await idJagTokenIssuer.issue({
        payload: {
          ...idJagAccessTokenPayload,
          // RFC 8693 §4.1: an act claim carried by the ID-JAG is preserved on
          // the issued access token, so downstream services still see WHO acts
          // on the subject's behalf (dropping it would silently turn the
          // delegation into impersonation).
          ...(idJagGrant.actor === undefined ? {} : { act: idJagGrant.actor }),
        },
        privateKey: c.get('privateKey'),
        keyId: c.get('keyId'),
      });

      const idJagAccessTokenMetadata: IdJagAccessTokenInfo = {
        // draft §4.4.1: the ID-JAG's sub is used as the local subject directly
        // (subject resolution by identical sub; JIT provisioning is out of scope).
        sub: idJagGrant.subject,
        clientId: idJagGrant.clientId,
        scope: idJagGrant.scope,
        expiresAt: idJagIssuedAt + idJagGrant.expiresIn,
        // Each redemption is its own grant: revoking one issued token must not
        // affect tokens from other redemptions of the same (re-presentable)
        // ID-JAG, so the payload's own jti doubles as the grant id.
        grantId: idJagAccessTokenPayload.jti,
        iat: idJagIssuedAt,
        nbf: idJagIssuedAt,
        audience: idJagAudience,
        issuer: idJagRedemptionConfig.issuer,
        jti: idJagAccessTokenPayload.jti,
        // The actor record is persisted too, so opaque-token introspection and
        // store-based tooling can surface it just like the JWT claim.
        ...(idJagGrant.actor === undefined ? {} : { act: idJagGrant.actor }),
      };
      await accessTokenStore.set(idJagAccessToken, idJagAccessTokenMetadata);

      // RFC 6749 §5.1: token responses MUST NOT be cached.
      c.header('Cache-Control', 'no-store');
      c.header('Pragma', 'no-cache');
      return c.json({
        access_token: idJagAccessToken,
        token_type: 'Bearer' as const,
        expires_in: idJagGrant.expiresIn,
        scope: idJagGrant.scope.join(' '),
      });
    }
```

catch 節には `IdJagError` の分岐が入る。

```typescript
    if (error instanceof IdJagError) {
      // ID-JAG errors use the RFC 6749 §5.2 shape and are always 400 — a 401
      // can only come from client authentication, which runs before both
      // branches and throws core's TokenError. Issuance failures map to
      // invalid_request / invalid_target / invalid_scope / unauthorized_client
      // (RFC 8693 §2.2.2); assertion failures on redemption map to
      // invalid_grant (RFC 7521 §4.1).
      c.header('Cache-Control', 'no-store');
      c.header('Pragma', 'no-cache');
      return c.json(
        { error: error.code, error_description: error.errorDescription },
        error.statusCode,
      );
    }
```

`--enable id-jag` を token-exchange なしで使った場合だけ、発行分岐の直後に「この OP の Token Exchange は ID-JAG 発行専用である」ことを伝えるフォールバック分岐が生成される（discovery が Token Exchange URN を広告するのに `unsupported_grant_type` で行き止まりになる状態を避けるため）。本サンプルは token-exchange も有効なので、この分岐は生成されていない。

### conformance.test.ts に入るもの

契約テストは 34 件で、偽の外部 IdP 鍵をテスト内で生成し、インライン JWKS で信頼リストに載せる（ネットワーク fetch なし）。
発行と redemption の連結（自 OP 発行 ID-JAG の自 OP redemption 拒否）、refresh token subject（発行、非消費、rotation 後の拒否、トグル無効時の拒否）、actor（act の記録、他クライアント宛て actor の拒否、redemption での act 引き継ぎと malformed 拒否）まで実 HTTP で固定する。
独自 actor_token 種別の契約（リゾルバ未設定時の拒否、リゾルバ経由の act チェーン発行、`null` の固定文言、id_token 種別でのリゾルバ不呼び出し）も同じ流儀で固定する。

```typescript
  // EXPERIMENTAL — Cross-App Access / ID-JAG
  // (draft-ietf-oauth-identity-assertion-authz-grant-04). Generated because this
  // provider was created with --enable id-jag. These tests pin the contract the
  // repository guarantees for both halves of XAA: issuing an ID-JAG on the
  // token-exchange grant (draft §4.3) and redeeming one on the jwt-bearer grant
  // (draft §4.4). Change the behavior and they fail, which is how a customized
  // OP learns it drifted.
  describe('Cross-App Access / ID-JAG (draft-ietf-oauth-identity-assertion-authz-grant)', () => {
    // RFC 7636 Appendix B example PKCE pair (verifier -> its S256 challenge).
    const XAA_PKCE_VERIFIER = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
    const XAA_PKCE_CHALLENGE_S256 = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
    const XAA_EXCHANGE_GRANT_TYPE = 'urn:ietf:params:oauth:grant-type:token-exchange';
    const XAA_JWT_BEARER_GRANT_TYPE = 'urn:ietf:params:oauth:grant-type:jwt-bearer';
    const XAA_ID_JAG_TOKEN_TYPE = 'urn:ietf:params:oauth:token-type:id-jag';
    const XAA_ID_TOKEN_TYPE = 'urn:ietf:params:oauth:token-type:id_token';
    // This OP's own issuer (createApp above runs on the default config).
    const XAA_OWN_ISSUER = 'http://localhost:3000';
    // The peer resource authorization server ID-JAGs are issued for.
    const XAA_PEER_AS_ISSUER = 'https://peer-as.conformance.example';
    // The fake external IdP whose signed ID-JAGs this OP redeems.
    const XAA_TRUSTED_IDP_ISSUER = 'https://trusted-idp.conformance.example';
    // Every unusable subject_token is rejected with this one description, and
    // an untrusted issuer is indistinguishable from a broken signature, so the
    // responses cannot be used as an existence / trust-list oracle.
    const XAA_SUBJECT_INVALID_DESCRIPTION = 'The provided subject_token is not valid';
    const XAA_ASSERTION_UNTRUSTED_DESCRIPTION =
      'The assertion issuer is not trusted or the assertion signature is invalid';

    let externalIdpPrivateKey: CryptoKey;
    let externalIdpJwk: Awaited<ReturnType<typeof exportPublicJwk>>;

    beforeAll(async () => {
      // The fake external IdP: its public JWK is trust-listed inline by the
      // tests below, so no jwks_uri fetch happens inside this suite.
      const externalIdpKeyPair = await crypto.subtle.generateKey(
        { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
        true,
        ['sign', 'verify'],
      );
      externalIdpPrivateKey = externalIdpKeyPair.privateKey;
      externalIdpJwk = await exportPublicJwk(externalIdpKeyPair.publicKey, 'external-idp-key');
    });

    // Pure helpers: they fetch, sign and parse only. Every assertion lives in an it().
    function xaaRelativeFrom(location: string | null): string {
      const url = new URL(location ?? '', 'http://localhost');
      return url.pathname + url.search;
    }

    function xaaCsrfFrom(html: string): string {
      return html.match(/name="csrf_token" value="([^"]+)"/)?.[1] ?? '';
    }

    function xaaB64Url(bytes: Uint8Array): string {
      let binary = '';
      for (const byte of bytes) binary += String.fromCharCode(byte);
      return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    }

    function xaaB64UrlJson(value: Record<string, unknown>): string {
      return xaaB64Url(new TextEncoder().encode(JSON.stringify(value)));
    }

    function xaaDecodeJwtSegment(segment: string): Record<string, unknown> {
      const base64 = segment.replace(/-/g, '+').replace(/_/g, '/');
      const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
      return JSON.parse(atob(padded)) as Record<string, unknown>;
    }

    function postXaaToken(
      fields: Record<string, string>,
      path = '/token',
      base: Record<string, string> = {},
    ): Promise<Response> {
      return app.request(path, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ ...base, ...fields }).toString(),
      });
    }

    // Drive authorize -> login -> consent over HTTP and hand back the code. No
    // assertions and no branching here: the flow contract lives in the it()s.
    async function xaaAuthorizeFlow(
      clientId: string,
      scope: string,
      username = 'testuser',
    ): Promise<string> {
      const authorizeUrl =
        '/authorize?response_type=code&client_id=' + clientId +
        '&redirect_uri=' + encodeURIComponent(REDIRECT_URI) +
        '&scope=' + encodeURIComponent(scope) +
        '&state=xaa-state&nonce=xaa-nonce' +
        '&code_challenge=' + XAA_PKCE_CHALLENGE_S256 + '&code_challenge_method=S256';

      const authorizeRes = await app.request(authorizeUrl);
      const loginPath = xaaRelativeFrom(authorizeRes.headers.get('Location'));
      // Carry forward whatever cookie /authorize set, exactly as a browser would
      // (with --enable transaction-binding it is the binding secret).
      const bindingCookie = (authorizeRes.headers.get('Set-Cookie') ?? '').split(';')[0] ?? '';
      const transactionId =
        new URL(loginPath, 'http://localhost').searchParams.get('transaction_id') ?? '';

      const loginGet = await app.request(loginPath, { headers: { Cookie: bindingCookie } });
      const loginRes = await app.request('/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: bindingCookie },
        body: new URLSearchParams({
          transaction_id: transactionId,
          csrf_token: xaaCsrfFrom(await loginGet.text()),
          username,
          password: 'password',
        }).toString(),
      });
      const consentPath = xaaRelativeFrom(loginRes.headers.get('Location'));

      const consentGet = await app.request(consentPath, { headers: { Cookie: bindingCookie } });
      const consentRes = await app.request('/consent', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: bindingCookie },
        body: new URLSearchParams({
          transaction_id: transactionId,
          csrf_token: xaaCsrfFrom(await consentGet.text()),
          action: 'approve',
        }).toString(),
      });
      const callback = new URL(consentRes.headers.get('Location') ?? '', 'http://localhost');
      return callback.searchParams.get('code') ?? '';
    }

    // The identity assertion the issuance half consumes: an ID Token from the
    // ordinary Authorization Code Flow of the given client.
    async function xaaCodeFlowTokens(
      clientId: string,
      username = 'testuser',
    ): Promise<Record<string, string>> {
      const code = await xaaAuthorizeFlow(clientId, 'openid profile', username);
      const res = await postXaaToken({
        client_id: clientId,
        client_secret: 's',
        grant_type: 'authorization_code',
        code,
        redirect_uri: REDIRECT_URI,
        code_verifier: XAA_PKCE_VERIFIER,
      });
      return (await res.json()) as Record<string, string>;
    }

    function issuanceRequest(overrides: Record<string, string> = {}): Promise<Response> {
      return postXaaToken(overrides, '/token', {
        client_id: 'c-idjag',
        client_secret: 's',
        grant_type: XAA_EXCHANGE_GRANT_TYPE,
        requested_token_type: XAA_ID_JAG_TOKEN_TYPE,
        subject_token_type: XAA_ID_TOKEN_TYPE,
        audience: XAA_PEER_AS_ISSUER,
        scope: 'openid profile',
      });
    }

    function redeemRequest(
      overrides: Record<string, string> = {},
      clientId = 'c-idjag',
    ): Promise<Response> {
      return postXaaToken(overrides, '/token', {
        client_id: clientId,
        client_secret: 's',
        grant_type: XAA_JWT_BEARER_GRANT_TYPE,
      });
    }

    // Sign an ID-JAG as the fake external IdP. An override set to undefined
    // removes the member (JSON.stringify drops undefined values).
    async function mintExternalIdJag(
      claims: Record<string, unknown>,
      header: Record<string, unknown> = {},
    ): Promise<string> {
      const nowSeconds = Math.floor(Date.now() / 1000);
      const encodedHeader = xaaB64UrlJson({
        alg: 'RS256',
        typ: 'oauth-id-jag+jwt',
        kid: 'external-idp-key',
        ...header,
      });
      const encodedPayload = xaaB64UrlJson({
        iss: XAA_TRUSTED_IDP_ISSUER,
        sub: 'testuser',
        aud: XAA_OWN_ISSUER,
        client_id: 'c-idjag',
        jti: 'conformance-jag',
        exp: nowSeconds + 300,
        iat: nowSeconds,
        scope: 'openid profile offline_access',
        ...claims,
      });
      const signingInput = encodedHeader + '.' + encodedPayload;
      const signature = await crypto.subtle.sign(
        'RSASSA-PKCS1-v1_5',
        externalIdpPrivateKey,
        new TextEncoder().encode(signingInput),
      );
      return signingInput + '.' + xaaB64Url(new Uint8Array(signature));
    }

    // Config helpers: flip the generated allow lists for one call and always
    // restore them, so the fail-safe empty defaults stay pinned by other tests.
    async function withIssuanceAudience<T>(fn: () => Promise<T>): Promise<T> {
      idJagConfig.allowedAudiences = [XAA_PEER_AS_ISSUER];
      try {
        return await fn();
      } finally {
        idJagConfig.allowedAudiences = [];
      }
    }

    async function withTrustedIdp<T>(fn: () => Promise<T>): Promise<T> {
      idJagConfig.trustedIdentityProviders = [
        { issuer: XAA_TRUSTED_IDP_ISSUER, jwks: { keys: [externalIdpJwk] } },
      ];
      try {
        return await fn();
      } finally {
        idJagConfig.trustedIdentityProviders = [];
      }
    }

    describe('ID-JAG issuance (draft §4.3)', () => {
      it('should issue an ID-JAG with the §3.1 claims and the §4.3.4 response members', async () => {
        const idToken = (await xaaCodeFlowTokens('c-idjag')).id_token;
        const res = await withIssuanceAudience(() =>
          issuanceRequest({ subject_token: idToken }),
        );
        const body = (await res.json()) as Record<string, unknown>;

        expect(res.status).toBe(200);
        expect(res.headers.get('Cache-Control')).toBe('no-store');
        expect(res.headers.get('Pragma')).toBe('no-cache');
        expect(Object.keys(body).sort()).toEqual([
          'access_token',
          'expires_in',
          'issued_token_type',
          'scope',
          'token_type',
        ]);
        expect(body.issued_token_type).toBe(XAA_ID_JAG_TOKEN_TYPE);
        // draft §4.3.4: the issued grant is NOT an access token.
        expect(body.token_type).toBe('N_A');
        expect(body.expires_in).toBe(300);
        expect(body.scope).toBe('openid profile');

        const segments = String(body.access_token).split('.');
        const header = xaaDecodeJwtSegment(segments[0] ?? '');
        const claims = xaaDecodeJwtSegment(segments[1] ?? '');
        // draft §3.1 / RFC 8725 §3.11: explicit typing, RS256, published kid.
        expect(header.typ).toBe('oauth-id-jag+jwt');
        expect(header.alg).toBe('RS256');
        expect(header.kid).toBe('test-key');
        expect(claims.iss).toBe(XAA_OWN_ISSUER);
        expect(claims.sub).toBe('testuser');
        expect(claims.aud).toBe(XAA_PEER_AS_ISSUER);
        expect(claims.client_id).toBe('c-idjag');
        expect(claims.scope).toBe('openid profile');
        expect(typeof claims.jti).toBe('string');
        expect((claims.exp as number) - (claims.iat as number)).toBe(300);
      });

      it('should omit the scope claim and return an empty scope when none is requested', async () => {
        const idToken = (await xaaCodeFlowTokens('c-idjag')).id_token;
        const res = await withIssuanceAudience(() =>
          issuanceRequest({ subject_token: idToken, scope: '' }),
        );
        const body = (await res.json()) as Record<string, unknown>;

        expect(res.status).toBe(200);
        expect(body.scope).toBe('');
        const claims = xaaDecodeJwtSegment(String(body.access_token).split('.')[1] ?? '');
        expect('scope' in claims).toBe(false);
      });

      it('should reject an audience outside the allow list with invalid_target', async () => {
        const idToken = (await xaaCodeFlowTokens('c-idjag')).id_token;
        // The generated default allow list is empty (fail safe), so the same
        // audience that succeeds above is rejected without the config flip.
        const res = await issuanceRequest({ subject_token: idToken });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_target',
          error_description: 'The requested audience is not allowed for ID-JAG issuance',
        });
      });

      it('should reject this issuer itself as audience with invalid_target', async () => {
        const idToken = (await xaaCodeFlowTokens('c-idjag')).id_token;
        // draft §9.3: cross-domain only — even an allow-listed own issuer is refused.
        idJagConfig.allowedAudiences = [XAA_OWN_ISSUER];
        try {
          const res = await issuanceRequest({ subject_token: idToken, audience: XAA_OWN_ISSUER });

          expect(res.status).toBe(400);
          expect(await res.json()).toEqual({
            error: 'invalid_target',
            error_description:
              'The requested audience must belong to a different trust domain than this authorization server',
          });
        } finally {
          idJagConfig.allowedAudiences = [];
        }
      });

      it('should reject an ID Token issued to another client with the fixed description', async () => {
        // draft §4.3.3: the assertion audience must be the authenticated client.
        const foreignIdToken = (await xaaCodeFlowTokens('c-conf')).id_token;
        const res = await withIssuanceAudience(() =>
          issuanceRequest({ subject_token: foreignIdToken }),
        );

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description: XAA_SUBJECT_INVALID_DESCRIPTION,
        });
      });

      it('should reject an access token presented as the subject with the same fixed description', async () => {
        const accessToken = (await xaaCodeFlowTokens('c-idjag')).access_token;
        const res = await withIssuanceAudience(() =>
          issuanceRequest({ subject_token: accessToken }),
        );

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description: XAA_SUBJECT_INVALID_DESCRIPTION,
        });
      });

      it('should reject a saml2 subject_token_type with invalid_request', async () => {
        const res = await issuanceRequest({
          subject_token: 'unused',
          subject_token_type: 'urn:ietf:params:oauth:token-type:saml2',
        });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description: 'Unsupported subject_token_type for ID-JAG issuance. Only urn:ietf:params:oauth:token-type:id_token or urn:ietf:params:oauth:token-type:refresh_token is supported.',
        });
      });

      it('should reject an actor_token with invalid_request', async () => {
        const res = await issuanceRequest({
          subject_token: 'unused',
          actor_token: 'unused',
          actor_token_type: XAA_ID_TOKEN_TYPE,
        });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description: 'actor_token is not supported for ID-JAG issuance',
        });
      });

      it('should reject a client without the token-exchange grant with unauthorized_client', async () => {
        // c-conf authenticates fine (client_secret_post) but never registered
        // the exchange URN.
        const res = await issuanceRequest({
          subject_token: 'unused',
          client_id: 'c-conf',
        });

        expect(res.status).toBe(400);
        expect(((await res.json()) as Record<string, unknown>).error).toBe('unauthorized_client');
      });

      it('should reject a public client with unauthorized_client', async () => {
        const res = await postXaaToken({
          client_id: 'c-public-idjag',
          grant_type: XAA_EXCHANGE_GRANT_TYPE,
          requested_token_type: XAA_ID_JAG_TOKEN_TYPE,
          subject_token: 'unused',
          subject_token_type: XAA_ID_TOKEN_TYPE,
          audience: XAA_PEER_AS_ISSUER,
        });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'unauthorized_client',
          error_description: 'Public clients are not allowed to request an ID-JAG',
        });
      });

      it('should cap the issued scopes at idJagConfig.allowedScopes with invalid_scope', async () => {
        const idToken = (await xaaCodeFlowTokens('c-idjag')).id_token;
        idJagConfig.allowedScopes = ['openid'];
        try {
          const res = await withIssuanceAudience(() =>
            issuanceRequest({ subject_token: idToken, scope: 'openid profile' }),
          );

          expect(res.status).toBe(400);
          expect(await res.json()).toEqual({
            error: 'invalid_scope',
            error_description: 'The requested scope exceeds the scopes allowed for ID-JAG issuance',
          });
        } finally {
          idJagConfig.allowedScopes = undefined;
        }
      });

      // draft §4.3 MAY: a refresh token of this OP may stand in for the ID Token.
      it('should issue an ID-JAG from a refresh token subject', async () => {
        const tokens = await xaaCodeFlowTokens('c-idjag');
        const res = await withIssuanceAudience(() =>
          issuanceRequest({
            subject_token: tokens.refresh_token,
            subject_token_type: 'urn:ietf:params:oauth:token-type:refresh_token',
          }),
        );
        const body = (await res.json()) as Record<string, unknown>;

        expect(res.status).toBe(200);
        expect(body.token_type).toBe('N_A');
        const claims = xaaDecodeJwtSegment(String(body.access_token).split('.')[1] ?? '');
        // The subject claims come from the refresh token's stored grant context.
        expect(claims.iss).toBe(XAA_OWN_ISSUER);
        expect(claims.sub).toBe('testuser');
        expect(claims.aud).toBe(XAA_PEER_AS_ISSUER);
        expect(typeof claims.auth_time).toBe('number');
      });

      it('should not consume the refresh token when issuing an ID-JAG', async () => {
        // The exchange is not the refresh grant: no rotation happens, so the
        // same refresh token mints a second ID-JAG (draft §4.4.3's renewal path).
        const tokens = await xaaCodeFlowTokens('c-idjag');
        const first = await withIssuanceAudience(() =>
          issuanceRequest({
            subject_token: tokens.refresh_token,
            subject_token_type: 'urn:ietf:params:oauth:token-type:refresh_token',
          }),
        );
        const second = await withIssuanceAudience(() =>
          issuanceRequest({
            subject_token: tokens.refresh_token,
            subject_token_type: 'urn:ietf:params:oauth:token-type:refresh_token',
          }),
        );

        expect(first.status).toBe(200);
        expect(second.status).toBe(200);
      });

      it('should reject a rotated refresh token subject with the fixed description', async () => {
        // OAuth 2.1 §4.3.1: presenting a rotated-out token is validated exactly
        // like the standard refresh grant would.
        const tokens = await xaaCodeFlowTokens('c-idjag');
        await postXaaToken({
          client_id: 'c-idjag',
          client_secret: 's',
          grant_type: 'refresh_token',
          refresh_token: tokens.refresh_token,
        });

        const res = await withIssuanceAudience(() =>
          issuanceRequest({
            subject_token: tokens.refresh_token,
            subject_token_type: 'urn:ietf:params:oauth:token-type:refresh_token',
          }),
        );

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description: XAA_SUBJECT_INVALID_DESCRIPTION,
        });
      });

      it('should reject a refresh token subject while allowRefreshTokenSubjects is off', async () => {
        const tokens = await xaaCodeFlowTokens('c-idjag');
        idJagConfig.allowRefreshTokenSubjects = false;
        try {
          const res = await withIssuanceAudience(() =>
            issuanceRequest({
              subject_token: tokens.refresh_token,
              subject_token_type: 'urn:ietf:params:oauth:token-type:refresh_token',
            }),
          );

          expect(res.status).toBe(400);
          expect(await res.json()).toEqual({
            error: 'invalid_request',
            error_description:
              'Unsupported subject_token_type for ID-JAG issuance. Only urn:ietf:params:oauth:token-type:id_token is supported.',
          });
        } finally {
          idJagConfig.allowRefreshTokenSubjects = true;
        }
      });

      // Extension (draft §9.7): actor tokens are an explicit opt-in; the
      // generated default keeps them off.
      it('should record the actor in the act claim when actor tokens are enabled', async () => {
        const subjectIdToken = (await xaaCodeFlowTokens('c-idjag')).id_token;
        const actorIdToken = (await xaaCodeFlowTokens('c-idjag', 'otheruser')).id_token;
        idJagConfig.allowActorTokens = true;
        try {
          const res = await withIssuanceAudience(() =>
            issuanceRequest({
              subject_token: subjectIdToken,
              actor_token: actorIdToken,
              actor_token_type: XAA_ID_TOKEN_TYPE,
            }),
          );
          const body = (await res.json()) as Record<string, unknown>;

          expect(res.status).toBe(200);
          const claims = xaaDecodeJwtSegment(String(body.access_token).split('.')[1] ?? '');
          // RFC 8693 §4.1: sub stays the resource owner; the actor appears only in act.
          expect(claims.sub).toBe('testuser');
          expect(claims.act).toEqual({ sub: 'otheruser' });
        } finally {
          idJagConfig.allowActorTokens = false;
        }
      });

      it('should reject an actor ID Token issued to another client with the fixed description', async () => {
        const subjectIdToken = (await xaaCodeFlowTokens('c-idjag')).id_token;
        const foreignActorToken = (await xaaCodeFlowTokens('c-conf')).id_token;
        idJagConfig.allowActorTokens = true;
        try {
          const res = await withIssuanceAudience(() =>
            issuanceRequest({
              subject_token: subjectIdToken,
              actor_token: foreignActorToken,
              actor_token_type: XAA_ID_TOKEN_TYPE,
            }),
          );

          expect(res.status).toBe(400);
          expect(await res.json()).toEqual({
            error: 'invalid_request',
            error_description: 'The provided actor_token is not valid',
          });
        } finally {
          idJagConfig.allowActorTokens = false;
        }
      });

      // Actor token types beyond id_token are an extension point: the library
      // validates the request structure, idJagConfig.actorTokenResolver
      // validates the token content. Without a resolver they stay rejected.
      it('should reject a custom actor_token_type while no resolver is configured', async () => {
        const subjectIdToken = (await xaaCodeFlowTokens('c-idjag')).id_token;
        idJagConfig.allowActorTokens = true;
        try {
          const res = await withIssuanceAudience(() =>
            issuanceRequest({
              subject_token: subjectIdToken,
              actor_token: 'opaque-actor-token',
              actor_token_type: 'urn:example:token-type:badge',
            }),
          );

          expect(res.status).toBe(400);
          expect(await res.json()).toEqual({
            error: 'invalid_request',
            error_description:
              'Unsupported actor_token_type for ID-JAG issuance. Only urn:ietf:params:oauth:token-type:id_token is supported.',
          });
        } finally {
          idJagConfig.allowActorTokens = false;
        }
      });

      it('should record the act chain resolved by the deployment actor token resolver', async () => {
        const subjectIdToken = (await xaaCodeFlowTokens('c-idjag')).id_token;
        idJagConfig.allowActorTokens = true;
        idJagConfig.actorTokenResolver = async ({ actorToken, actorTokenType, clientId }) =>
          actorTokenType === 'urn:example:token-type:badge' &&
          actorToken === 'badge-7' &&
          clientId === 'c-idjag'
            ? { sub: 'badge-actor', act: { sub: 'upstream-actor' } }
            : null;
        try {
          const res = await withIssuanceAudience(() =>
            issuanceRequest({
              subject_token: subjectIdToken,
              actor_token: 'badge-7',
              actor_token_type: 'urn:example:token-type:badge',
            }),
          );
          const body = (await res.json()) as Record<string, unknown>;

          expect(res.status).toBe(200);
          const claims = xaaDecodeJwtSegment(String(body.access_token).split('.')[1] ?? '');
          // The subject stays the resource owner; the resolver's chain lands in act.
          expect(claims.sub).toBe('testuser');
          expect(claims.act).toEqual({ sub: 'badge-actor', act: { sub: 'upstream-actor' } });
        } finally {
          idJagConfig.allowActorTokens = false;
          idJagConfig.actorTokenResolver = undefined;
        }
      });

      it('should answer a null from the actor token resolver with the fixed description', async () => {
        const subjectIdToken = (await xaaCodeFlowTokens('c-idjag')).id_token;
        idJagConfig.allowActorTokens = true;
        idJagConfig.actorTokenResolver = async () => null;
        try {
          const res = await withIssuanceAudience(() =>
            issuanceRequest({
              subject_token: subjectIdToken,
              actor_token: 'opaque-actor-token',
              actor_token_type: 'urn:example:token-type:badge',
            }),
          );

          expect(res.status).toBe(400);
          expect(await res.json()).toEqual({
            error: 'invalid_request',
            error_description: 'The provided actor_token is not valid',
          });
        } finally {
          idJagConfig.allowActorTokens = false;
          idJagConfig.actorTokenResolver = undefined;
        }
      });

      it('should keep the built-in id_token actor validation even when a resolver is configured', async () => {
        const subjectIdToken = (await xaaCodeFlowTokens('c-idjag')).id_token;
        let resolverCalls = 0;
        idJagConfig.allowActorTokens = true;
        idJagConfig.actorTokenResolver = async () => {
          resolverCalls += 1;
          return { sub: 'resolver-must-not-decide-this' };
        };
        try {
          const res = await withIssuanceAudience(() =>
            issuanceRequest({
              subject_token: subjectIdToken,
              actor_token: 'not-a-jwt',
              actor_token_type: XAA_ID_TOKEN_TYPE,
            }),
          );

          expect(res.status).toBe(400);
          expect(await res.json()).toEqual({
            error: 'invalid_request',
            error_description: 'The provided actor_token is not valid',
          });
          expect(resolverCalls).toBe(0);
        } finally {
          idJagConfig.allowActorTokens = false;
          idJagConfig.actorTokenResolver = undefined;
        }
      });
    });

    describe('ID-JAG redemption (draft §4.4)', () => {
      it('should redeem a trusted ID-JAG for an access token of this AS', async () => {
        const assertion = await mintExternalIdJag({});
        const res = await withTrustedIdp(() => redeemRequest({ assertion }));
        const body = (await res.json()) as Record<string, unknown>;

        expect(res.status).toBe(200);
        expect(res.headers.get('Cache-Control')).toBe('no-store');
        expect(res.headers.get('Pragma')).toBe('no-cache');
        // draft §4.4.2 / §4.4.3: a plain token response — no refresh_token (the
        // re-presentable ID-JAG replaces it) and no id_token (this is not an
        // OIDC authentication flow).
        expect(Object.keys(body).sort()).toEqual([
          'access_token',
          'expires_in',
          'scope',
          'token_type',
        ]);
        expect(body.token_type).toBe('Bearer');
        expect(body.expires_in).toBe(3600);
        // offline_access is always dropped: no refresh token is ever issued here.
        expect(body.scope).toBe('openid profile');

        const claims = xaaDecodeJwtSegment(String(body.access_token).split('.')[1] ?? '');
        // The access token is this AS's own (draft §1: the IdP never mints
        // tokens for the resource AS), for the ID-JAG's subject and client.
        expect(claims.iss).toBe(XAA_OWN_ISSUER);
        expect(claims.sub).toBe('testuser');
        expect(claims.client_id).toBe('c-idjag');
      });

      it('should let the redeemed access token pass the UserInfo endpoint', async () => {
        const assertion = await mintExternalIdJag({});
        const redeemed = await withTrustedIdp(() => redeemRequest({ assertion }));
        const accessToken = ((await redeemed.json()) as Record<string, string>).access_token;

        const res = await app.request('/userinfo', {
          headers: { Authorization: 'Bearer ' + accessToken },
        });
        const body = (await res.json()) as Record<string, unknown>;

        expect(res.status).toBe(200);
        expect(body.sub).toBe('testuser');
      });

      it('should report a redeemed access token active with the ID-JAG subject and client', async () => {
        const assertion = await mintExternalIdJag({});
        const redeemed = await withTrustedIdp(() => redeemRequest({ assertion }));
        const redeemedBody = (await redeemed.json()) as Record<string, string>;

        const res = await postXaaToken({}, '/introspect', {
          token: redeemedBody.access_token,
          client_id: 'c-idjag',
          client_secret: 's',
        });
        const body = (await res.json()) as Record<string, unknown>;

        expect(res.status).toBe(200);
        expect(body.active).toBe(true);
        // draft §4.4.1: the ID-JAG sub becomes the local subject directly, and
        // the token is bound to the client that redeemed the grant.
        expect(body.sub).toBe('testuser');
        expect(body.client_id).toBe('c-idjag');
        expect(body.scope).toBe('openid profile');
      });

      it('should accept the same ID-JAG again while it is valid', async () => {
        // draft §4.4.3: re-presenting the still-valid grant replaces the refresh
        // token, so a second redemption MUST succeed (no jti replay store).
        const assertion = await mintExternalIdJag({});
        const first = await withTrustedIdp(() => redeemRequest({ assertion }));
        const second = await withTrustedIdp(() => redeemRequest({ assertion }));

        expect(first.status).toBe(200);
        expect(second.status).toBe(200);
      });

      it('should answer an untrusted issuer and a broken signature identically', async () => {
        const untrusted = await mintExternalIdJag({ iss: 'https://unknown-idp.example.org' });
        const [h, p] = (await mintExternalIdJag({})).split('.');
        const tampered = h + '.' + p + '.AAAA';

        const untrustedRes = await withTrustedIdp(() => redeemRequest({ assertion: untrusted }));
        const tamperedRes = await withTrustedIdp(() => redeemRequest({ assertion: tampered }));
        const expected = {
          error: 'invalid_grant',
          error_description: XAA_ASSERTION_UNTRUSTED_DESCRIPTION,
        };

        expect(untrustedRes.status).toBe(400);
        expect(tamperedRes.status).toBe(400);
        expect(await untrustedRes.json()).toEqual(expected);
        expect(await tamperedRes.json()).toEqual(expected);
      });

      it('should reject every assertion when no identity provider is trusted', async () => {
        // The generated default trust list is empty (fail safe).
        const assertion = await mintExternalIdJag({});
        const res = await redeemRequest({ assertion });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_grant',
          error_description: XAA_ASSERTION_UNTRUSTED_DESCRIPTION,
        });
      });

      it('should reject an ID-JAG addressed to another authorization server with invalid_grant', async () => {
        const assertion = await mintExternalIdJag({ aud: 'https://other-as.example.org' });
        const res = await withTrustedIdp(() => redeemRequest({ assertion }));

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_grant',
          error_description: 'The assertion audience does not match this authorization server',
        });
      });

      it('should reject an ID-JAG bound to another client with invalid_grant', async () => {
        // draft §4.4.1 client continuity: c-idjag-other authenticates correctly
        // but presents a grant that names c-idjag.
        const assertion = await mintExternalIdJag({});
        const res = await withTrustedIdp(() => redeemRequest({ assertion }, 'c-idjag-other'));

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_grant',
          error_description: 'The assertion client_id does not match the authenticated client',
        });
      });

      it('should reject a JWT without the ID-JAG typ with invalid_grant', async () => {
        // RFC 8725 §3.11 explicit typing: an ID Token (typ JWT) can never be
        // redeemed as an ID-JAG even with otherwise plausible claims.
        const assertion = await mintExternalIdJag({}, { typ: 'JWT' });
        const res = await withTrustedIdp(() => redeemRequest({ assertion }));

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_grant',
          error_description: 'The assertion typ must be oauth-id-jag+jwt',
        });
      });

      it('should reject an expired ID-JAG with invalid_grant', async () => {
        const nowSeconds = Math.floor(Date.now() / 1000);
        const assertion = await mintExternalIdJag({ exp: nowSeconds - 120, iat: nowSeconds - 400 });
        const res = await withTrustedIdp(() => redeemRequest({ assertion }));

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_grant',
          error_description: 'The assertion has expired',
        });
      });

      it('should reject a client without the jwt-bearer grant with unauthorized_client', async () => {
        // c-conf authenticates fine (client_secret_post) but never registered
        // the jwt-bearer URN.
        const res = await redeemRequest({ assertion: 'unused', client_id: 'c-conf' });

        expect(res.status).toBe(400);
        expect(((await res.json()) as Record<string, unknown>).error).toBe('unauthorized_client');
      });

      it('should reject a public client with unauthorized_client', async () => {
        const res = await postXaaToken({
          client_id: 'c-public-idjag',
          grant_type: XAA_JWT_BEARER_GRANT_TYPE,
          assertion: 'unused',
        });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'unauthorized_client',
          error_description: 'Public clients are not allowed to use the jwt-bearer grant type',
        });
      });

      it('should preserve the act claim of an actor-bearing ID-JAG on the issued access token', async () => {
        // RFC 8693 §4.1: the actor record survives the redemption, on the JWT
        // and in the store alike — dropping it would hide who actually acts.
        const assertion = await mintExternalIdJag({ act: { sub: 'external-actor' } });
        const res = await withTrustedIdp(() => redeemRequest({ assertion }));
        const body = (await res.json()) as Record<string, unknown>;

        expect(res.status).toBe(200);
        const claims = xaaDecodeJwtSegment(String(body.access_token).split('.')[1] ?? '');
        expect(claims.sub).toBe('testuser');
        expect(claims.act).toEqual({ sub: 'external-actor' });
      });

      it('should reject a malformed act claim with invalid_grant', async () => {
        const assertion = await mintExternalIdJag({ act: { role: 'admin' } });
        const res = await withTrustedIdp(() => redeemRequest({ assertion }));

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_grant',
          error_description: 'The assertion act claim is malformed',
        });
      });

      it('should refuse to redeem an ID-JAG this authorization server issued itself', async () => {
        // draft §9.3: the full chain — a real ID-JAG issued by this OP (for the
        // peer AS) must not be exchangeable for this OP's own access token,
        // whatever the trust list says.
        const idToken = (await xaaCodeFlowTokens('c-idjag')).id_token;
        const issued = await withIssuanceAudience(() =>
          issuanceRequest({ subject_token: idToken }),
        );
        const selfIssuedJag = ((await issued.json()) as Record<string, string>).access_token;

        const res = await withTrustedIdp(() => redeemRequest({ assertion: selfIssuedJag }));

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_grant',
          error_description: 'An assertion issued by this authorization server cannot be redeemed here',
        });
      });
    });

    describe('Discovery advertisement (draft §7)', () => {
      it('should advertise both XAA grant types and the profile metadata', async () => {
        const res = await app.request('/.well-known/openid-configuration');
        const metadata = (await res.json()) as Record<string, unknown>;
        const grantTypes = metadata.grant_types_supported as string[];

        expect(grantTypes.includes(XAA_EXCHANGE_GRANT_TYPE)).toBe(true);
        expect(grantTypes.includes(XAA_JWT_BEARER_GRANT_TYPE)).toBe(true);
        // draft §7.1 / §7.2: profile support only — the trusted-IdP list and the
        // audience allow list are deliberately NOT disclosed (draft §9.4).
        expect(metadata.identity_chaining_requested_token_types_supported).toEqual([
          'urn:ietf:params:oauth:token-type:id-jag',
        ]);
        expect(metadata.authorization_grant_profiles_supported).toEqual([
          'urn:ietf:params:oauth:grant-profile:id-jag',
        ]);
      });
    });
  });
```

### 他フレームワークの差分

express / fastify / nextjs は web-standard テンプレートが hono のトークンルートテンプレートを変換共有しているため、分岐の内容は同一になる（nextjs は相対 import の拡張子だけ落ちる）。
conformance ブロックも同じ関数を両テンプレートが補間する。

### サンプルと E2E 環境の配線

hono-cloudflare サンプルの手書きエントリ（`src/app.ts`）は、環境変数から `idJagConfig` を上書きする。
これで 2 インスタンスの信頼関係が env だけで組める。

```typescript
// EXPERIMENTAL (Cross-App Access / ID-JAG): wire the trust configuration from
// env vars so two instances of this sample can play the IdP and the resource
// authorization server against each other (tests/e2e does exactly that).
// With the vars unset the generated fail-safe defaults stay: no ID-JAG is
// issued and none is accepted.
const xaaAllowedAudiences = (bindings.XAA_ALLOWED_AUDIENCES ?? '')
  .split(',')
  .map((value) => value.trim())
  .filter((value) => value.length > 0);
if (xaaAllowedAudiences.length > 0) {
  idJagConfig.allowedAudiences = xaaAllowedAudiences;
}
if (bindings.XAA_TRUSTED_IDP_ISSUER) {
  idJagConfig.trustedIdentityProviders = [
    {
      issuer: bindings.XAA_TRUSTED_IDP_ISSUER,
      jwksUri:
        bindings.XAA_TRUSTED_IDP_JWKS_URI ||
        `${bindings.XAA_TRUSTED_IDP_ISSUER}/.well-known/jwks.json`,
    },
  ];
}
// Actor tokens (act claim) are an opt-in extension beyond the draft's
// normative scope, so they stay off unless the deployment flips this.
if (bindings.XAA_ALLOW_ACTOR_TOKENS === '1') {
  idJagConfig.allowActorTokens = true;
}
// Demo of the actor_token extension point: actor_token types other than
// id_token are only accepted through a deployment-provided resolver, and the
// resolver owns the CONTENT validation (the library only checks the request
// structure and the shape of the returned act value). This one accepts an
// access token this very OP issued, by looking it up in the OP's own store —
// anything unknown, expired, or issued to a different client resolves to null,
// which the endpoint answers with the fixed invalid_request description.
if (bindings.XAA_ACTOR_TOKEN_RESOLVER === 'access-token') {
  idJagConfig.actorTokenResolver = async ({ actorToken, actorTokenType, clientId }) => {
    if (actorTokenType !== 'urn:ietf:params:oauth:token-type:access_token') return null;
    const stores = createD1ProviderStores(bindings.DB);
    const info = await stores.accessTokenStore.get(actorToken);
    if (info === undefined || info.clientId !== clientId) return null;
    if (info.expiresAt <= Math.floor(Date.now() / 1000)) return null;
    return { sub: info.sub };
  };
}
```

## E2E テストの全文と解説

E2E は playwright.config.ts の webServer にサンプル OP の 2 インスタンス目（リソース AS 役、別ポート、別 issuer、別永続化パス）を追加し、1 インスタンス目（IdP 役）に `XAA_ALLOWED_AUDIENCES`、2 インスタンス目に `XAA_TRUSTED_IDP_ISSUER` / `XAA_TRUSTED_IDP_JWKS_URI` を渡す。
受領側は IdP の JWKS エンドポイントを実際に fetch して署名検証するので、鍵の受け渡しも本番同様の経路になる。
spec は実ブラウザで SSO を完走して ID トークンを取り、バックチャネルで発行と redemption を行う。
refresh token subject の連鎖（ブラウザフローで得た RT からの発行と redemption）と、actor の連鎖（別ブラウザコンテキストの別ユーザー ID トークンを actor_token にし、`act` が ID-JAG と redemption 後のアクセストークンの両方で保たれること）も通しで検証する。actor は IdP 役インスタンスの `XAA_ALLOW_ACTOR_TOKENS` 環境変数で有効化している。
さらに、IdP 役インスタンスの `XAA_ACTOR_TOKEN_RESOLVER=access-token` でサンプルのデモリゾルバ（自 OP 発行アクセストークンの自ストア照合）を有効化し、別ユーザーの実アクセストークンを actor_token（`...:access_token` 種別）にした発行と redemption の連鎖も通しで検証する。
id-jag なしで生成されたサンプル OP では discovery 判定で skip する。

```typescript
import { expect, test, type APIRequestContext } from '@playwright/test';

const host = process.env.E2E_HOST ?? '127.0.0.1';
const clientPort = Number(process.env.E2E_CLIENT_PORT ?? '3020');
const xaaOpPort = Number(process.env.E2E_XAA_OP_PORT ?? '3040');
const clientBaseURL =
  process.env.E2E_CLIENT_BASE_URL ?? `http://${host}:${clientPort}`;
const xaaIssuer = process.env.E2E_XAA_ISSUER ?? `http://${host}:${xaaOpPort}`;
const clientId = 'e2e-client';
const clientSecret = 'e2e-client-secret';

const EXCHANGE_GRANT_TYPE = 'urn:ietf:params:oauth:grant-type:token-exchange';
const JWT_BEARER_GRANT_TYPE = 'urn:ietf:params:oauth:grant-type:jwt-bearer';
const ID_JAG_TOKEN_TYPE = 'urn:ietf:params:oauth:token-type:id-jag';
const ID_TOKEN_TYPE = 'urn:ietf:params:oauth:token-type:id_token';
const REFRESH_TOKEN_TYPE = 'urn:ietf:params:oauth:token-type:refresh_token';
const ACCESS_TOKEN_TYPE = 'urn:ietf:params:oauth:token-type:access_token';
const ID_JAG_GRANT_PROFILE = 'urn:ietf:params:oauth:grant-profile:id-jag';

/**
 * EXPERIMENTAL — Cross-App Access / ID-JAG
 * (draft-ietf-oauth-identity-assertion-authz-grant-04).
 *
 * Two OP instances of the sample play the two trust domains: the first
 * (baseURL) is the IdP that issues ID-JAGs, the second (xaaIssuer) is the
 * resource authorization server that redeems them. The second instance only
 * starts for the hono sample, and only an OP generated with --enable id-jag
 * advertises the profile — every test here skips itself otherwise, so the
 * shared spec suite stays green across all sample OPs.
 */
test.describe('Cross-App Access / ID-JAG (draft-ietf-oauth-identity-assertion-authz-grant)', () => {
  test('should walk the full XAA chain: SSO, ID-JAG issuance, redemption, API access', async ({
    page,
    request,
    baseURL,
  }) => {
    const idpIssuer = requireBaseUrl(baseURL);
    test.skip(!(await supportsXaa(request, idpIssuer)), XAA_SKIP_REASON);

    // (1) SSO: the ordinary Authorization Code Flow in a real browser yields
    // the Identity Assertion (ID Token) at the IdP.
    const idToken = await obtainIdToken(page);

    // (2) Token Exchange at the IdP (draft §4.3): trade the ID Token for an
    // ID-JAG addressed to the second OP's trust domain.
    const exchangeRes = await request.post(`${idpIssuer}/token`, {
      form: {
        grant_type: EXCHANGE_GRANT_TYPE,
        requested_token_type: ID_JAG_TOKEN_TYPE,
        subject_token: idToken,
        subject_token_type: ID_TOKEN_TYPE,
        audience: xaaIssuer,
        scope: 'openid profile',
        client_id: clientId,
        client_secret: clientSecret,
      },
    });
    expect(exchangeRes.status()).toBe(200);
    const exchangeBody = (await exchangeRes.json()) as Record<string, unknown>;
    // draft §4.3.4: the ID-JAG travels in access_token for historical reasons,
    // but token_type N_A says it is NOT an access token.
    expect(exchangeBody.issued_token_type).toBe(ID_JAG_TOKEN_TYPE);
    expect(exchangeBody.token_type).toBe('N_A');
    expect(exchangeBody.expires_in).toBe(300);
    expect(exchangeBody.scope).toBe('openid profile');

    const idJag = String(exchangeBody.access_token);
    const jagHeader = decodeJwtSegment(idJag.split('.')[0] ?? '');
    const jagClaims = decodeJwtSegment(idJag.split('.')[1] ?? '');
    // draft §3.1: explicit typing plus the cross-domain addressing.
    expect(jagHeader.typ).toBe('oauth-id-jag+jwt');
    expect(jagHeader.alg).toBe('RS256');
    expect(jagHeader.kid).toBe('e2e-rs256-key');
    expect(jagClaims.iss).toBe(idpIssuer);
    expect(jagClaims.aud).toBe(xaaIssuer);
    expect(jagClaims.sub).toBe('testuser');
    expect(jagClaims.client_id).toBe(clientId);

    // (3) Redemption at the resource AS (draft §4.4): the jwt-bearer grant.
    // The second OP verifies the signature against the IdP's live JWKS.
    const redeemRes = await request.post(`${xaaIssuer}/token`, {
      form: {
        grant_type: JWT_BEARER_GRANT_TYPE,
        assertion: idJag,
        client_id: clientId,
        client_secret: clientSecret,
      },
    });
    expect(redeemRes.status()).toBe(200);
    const redeemBody = (await redeemRes.json()) as Record<string, unknown>;
    // draft §4.4.2 / §4.4.3: a plain token response — no refresh_token (the
    // re-presentable ID-JAG replaces it) and no id_token.
    expect(Object.keys(redeemBody).sort()).toEqual([
      'access_token',
      'expires_in',
      'scope',
      'token_type',
    ]);
    expect(redeemBody.token_type).toBe('Bearer');
    expect(redeemBody.scope).toBe('openid profile');

    // The access token is minted by the resource AS itself, not by the IdP.
    const accessTokenClaims = decodeJwtSegment(
      String(redeemBody.access_token).split('.')[1] ?? '',
    );
    expect(accessTokenClaims.iss).toBe(xaaIssuer);
    expect(accessTokenClaims.sub).toBe('testuser');
    expect(accessTokenClaims.client_id).toBe(clientId);

    // (4) API access in the second trust domain: the resource AS resolves the
    // ID-JAG subject to its own local user of the same sub.
    const userInfoRes = await request.get(`${xaaIssuer}/userinfo`, {
      headers: { Authorization: `Bearer ${String(redeemBody.access_token)}` },
    });
    expect(userInfoRes.status()).toBe(200);
    expect(((await userInfoRes.json()) as { sub: string }).sub).toBe('testuser');
  });

  // draft §4.3.2 / §4.4.3: when the ID Token has expired, the refresh token
  // from the same SSO stands in as the subject and yields a fresh ID-JAG
  // without a new sign-on round trip.
  test('should issue and redeem an ID-JAG from a refresh token subject', async ({
    page,
    request,
    baseURL,
  }) => {
    const idpIssuer = requireBaseUrl(baseURL);
    test.skip(!(await supportsXaa(request, idpIssuer)), XAA_SKIP_REASON);

    const { refreshToken } = await obtainTokens(page);
    expect(refreshToken).not.toBe('');

    const exchangeRes = await request.post(`${idpIssuer}/token`, {
      form: {
        grant_type: EXCHANGE_GRANT_TYPE,
        requested_token_type: ID_JAG_TOKEN_TYPE,
        subject_token: refreshToken,
        subject_token_type: REFRESH_TOKEN_TYPE,
        audience: xaaIssuer,
        scope: 'openid profile',
        client_id: clientId,
        client_secret: clientSecret,
      },
    });
    expect(exchangeRes.status()).toBe(200);
    const exchangeBody = (await exchangeRes.json()) as Record<string, unknown>;
    expect(exchangeBody.token_type).toBe('N_A');

    const idJag = String(exchangeBody.access_token);
    const jagClaims = decodeJwtSegment(idJag.split('.')[1] ?? '');
    // The subject claims come from the refresh token's stored grant context.
    expect(jagClaims.sub).toBe('testuser');
    expect(typeof jagClaims.auth_time).toBe('number');

    const redeemRes = await request.post(`${xaaIssuer}/token`, {
      form: {
        grant_type: JWT_BEARER_GRANT_TYPE,
        assertion: idJag,
        client_id: clientId,
        client_secret: clientSecret,
      },
    });
    expect(redeemRes.status()).toBe(200);
    expect(((await redeemRes.json()) as Record<string, unknown>).token_type).toBe('Bearer');
  });

  // Extension (draft §9.7): the IdP records who acts on the subject's behalf,
  // and the resource AS preserves that record on its own access token.
  test('should carry the actor through the chain as the act claim', async ({
    page,
    browser,
    request,
    baseURL,
  }) => {
    const idpIssuer = requireBaseUrl(baseURL);
    test.skip(!(await supportsXaa(request, idpIssuer)), XAA_SKIP_REASON);

    // Subject: testuser signs in in the default context.
    const subjectIdToken = await obtainIdToken(page);
    // Actor: otheruser runs the same flow in an isolated context, so the OP's
    // browser-session cookie of the first login cannot leak into it.
    const actorContext = await browser.newContext();
    const actorIdToken = await obtainIdToken(await actorContext.newPage(), 'otheruser');
    await actorContext.close();

    const exchangeRes = await request.post(`${idpIssuer}/token`, {
      form: {
        grant_type: EXCHANGE_GRANT_TYPE,
        requested_token_type: ID_JAG_TOKEN_TYPE,
        subject_token: subjectIdToken,
        subject_token_type: ID_TOKEN_TYPE,
        actor_token: actorIdToken,
        actor_token_type: ID_TOKEN_TYPE,
        audience: xaaIssuer,
        scope: 'openid profile',
        client_id: clientId,
        client_secret: clientSecret,
      },
    });
    expect(exchangeRes.status()).toBe(200);
    const idJag = String(
      ((await exchangeRes.json()) as Record<string, unknown>).access_token,
    );
    const jagClaims = decodeJwtSegment(idJag.split('.')[1] ?? '');
    // RFC 8693 §4.1: sub stays the resource owner; the actor appears only in act.
    expect(jagClaims.sub).toBe('testuser');
    expect(jagClaims.act).toEqual({ sub: 'otheruser' });

    const redeemRes = await request.post(`${xaaIssuer}/token`, {
      form: {
        grant_type: JWT_BEARER_GRANT_TYPE,
        assertion: idJag,
        client_id: clientId,
        client_secret: clientSecret,
      },
    });
    expect(redeemRes.status()).toBe(200);
    const redeemBody = (await redeemRes.json()) as Record<string, unknown>;

    const accessTokenClaims = decodeJwtSegment(
      String(redeemBody.access_token).split('.')[1] ?? '',
    );
    expect(accessTokenClaims.sub).toBe('testuser');
    expect(accessTokenClaims.act).toEqual({ sub: 'otheruser' });
  });

  // Extension point: actor_token types beyond id_token are accepted only
  // through a deployment-provided resolver that owns the content validation.
  // The sample OP wires a demo resolver (XAA_ACTOR_TOKEN_RESOLVER=access-token)
  // that resolves an access token this IdP itself issued via its own store.
  test('should resolve a custom actor_token type through the deployment resolver', async ({
    page,
    browser,
    request,
    baseURL,
  }) => {
    const idpIssuer = requireBaseUrl(baseURL);
    test.skip(!(await supportsXaa(request, idpIssuer)), XAA_SKIP_REASON);

    const subjectIdToken = await obtainIdToken(page);
    // The actor's credential here is otheruser's ACCESS token (not an ID
    // Token), obtained in an isolated browser context.
    const actorContext = await browser.newContext();
    const { accessToken: actorAccessToken } = await obtainTokens(
      await actorContext.newPage(),
      'otheruser',
    );
    await actorContext.close();
    expect(actorAccessToken).not.toBe('');

    const exchangeRes = await request.post(`${idpIssuer}/token`, {
      form: {
        grant_type: EXCHANGE_GRANT_TYPE,
        requested_token_type: ID_JAG_TOKEN_TYPE,
        subject_token: subjectIdToken,
        subject_token_type: ID_TOKEN_TYPE,
        actor_token: actorAccessToken,
        actor_token_type: ACCESS_TOKEN_TYPE,
        audience: xaaIssuer,
        scope: 'openid profile',
        client_id: clientId,
        client_secret: clientSecret,
      },
    });
    expect(exchangeRes.status()).toBe(200);
    const idJag = String(
      ((await exchangeRes.json()) as Record<string, unknown>).access_token,
    );
    const jagClaims = decodeJwtSegment(idJag.split('.')[1] ?? '');
    expect(jagClaims.sub).toBe('testuser');
    expect(jagClaims.act).toEqual({ sub: 'otheruser' });

    const redeemRes = await request.post(`${xaaIssuer}/token`, {
      form: {
        grant_type: JWT_BEARER_GRANT_TYPE,
        assertion: idJag,
        client_id: clientId,
        client_secret: clientSecret,
      },
    });
    expect(redeemRes.status()).toBe(200);
    const redeemBody = (await redeemRes.json()) as Record<string, unknown>;
    const accessTokenClaims = decodeJwtSegment(
      String(redeemBody.access_token).split('.')[1] ?? '',
    );
    expect(accessTokenClaims.act).toEqual({ sub: 'otheruser' });
  });

  test('should advertise the XAA metadata on both trust domains', async ({
    request,
    baseURL,
  }) => {
    const idpIssuer = requireBaseUrl(baseURL);
    test.skip(!(await supportsXaa(request, idpIssuer)), XAA_SKIP_REASON);

    const idpMetadata = await discovery(request, idpIssuer);
    const asMetadata = await discovery(request, xaaIssuer);

    // draft §7.1: the IdP side announces the identity-chaining token type.
    expect(idpMetadata.identity_chaining_requested_token_types_supported).toEqual([
      ID_JAG_TOKEN_TYPE,
    ]);
    // draft §7.2: the resource AS side announces the grant profile and, with
    // it, MUST announce the jwt-bearer grant.
    expect(asMetadata.authorization_grant_profiles_supported).toEqual([ID_JAG_GRANT_PROFILE]);
    expect((asMetadata.grant_types_supported as string[]).includes(JWT_BEARER_GRANT_TYPE)).toBe(
      true,
    );
  });

  test('should refuse to redeem the ID-JAG at the IdP that issued it', async ({
    page,
    request,
    baseURL,
  }) => {
    const idpIssuer = requireBaseUrl(baseURL);
    test.skip(!(await supportsXaa(request, idpIssuer)), XAA_SKIP_REASON);

    const idJag = await obtainIdJag(page, request, idpIssuer);

    // draft §9.3: same trust domain — the issuing OP must never turn its own
    // ID-JAG into its own access token, whatever grants the client holds.
    const res = await request.post(`${idpIssuer}/token`, {
      form: {
        grant_type: JWT_BEARER_GRANT_TYPE,
        assertion: idJag,
        client_id: clientId,
        client_secret: clientSecret,
      },
    });

    expect(res.status()).toBe(400);
    expect(await res.json()).toEqual({
      error: 'invalid_grant',
      error_description: 'An assertion issued by this authorization server cannot be redeemed here',
    });
  });

  test('should refuse an ID-JAG presented by a client it does not name', async ({
    page,
    request,
    baseURL,
  }) => {
    const idpIssuer = requireBaseUrl(baseURL);
    test.skip(!(await supportsXaa(request, idpIssuer)), XAA_SKIP_REASON);

    const idJag = await obtainIdJag(page, request, idpIssuer);

    // draft §4.4.1 client continuity: e2e-xaa-other authenticates correctly at
    // the resource AS but presents a grant that names e2e-client.
    const res = await request.post(`${xaaIssuer}/token`, {
      form: {
        grant_type: JWT_BEARER_GRANT_TYPE,
        assertion: idJag,
        client_id: 'e2e-xaa-other',
        client_secret: 'e2e-xaa-other-secret',
      },
    });

    expect(res.status()).toBe(400);
    expect(await res.json()).toEqual({
      error: 'invalid_grant',
      error_description: 'The assertion client_id does not match the authenticated client',
    });
  });

  test('should refuse a tampered ID-JAG with the fixed untrusted description', async ({
    page,
    request,
    baseURL,
  }) => {
    const idpIssuer = requireBaseUrl(baseURL);
    test.skip(!(await supportsXaa(request, idpIssuer)), XAA_SKIP_REASON);

    const idJag = await obtainIdJag(page, request, idpIssuer);
    const [header = '', payload = ''] = idJag.split('.');

    const res = await request.post(`${xaaIssuer}/token`, {
      form: {
        grant_type: JWT_BEARER_GRANT_TYPE,
        assertion: `${header}.${payload}.AAAA`,
        client_id: clientId,
        client_secret: clientSecret,
      },
    });

    expect(res.status()).toBe(400);
    // The same description covers "issuer unknown" — the response never says
    // which trust check failed, so it cannot enumerate the trusted-IdP list.
    expect(await res.json()).toEqual({
      error: 'invalid_grant',
      error_description: 'The assertion issuer is not trusted or the assertion signature is invalid',
    });
  });
});

const XAA_SKIP_REASON =
  'This sample OP was generated without --enable id-jag, or the second (resource AS) OP instance is not running';

/**
 * Complete the ordinary Authorization Code Flow at the E2E client app as the
 * given user and read the raw tokens off the client's result page.
 */
async function obtainTokens(
  page: import('@playwright/test').Page,
  username = 'testuser',
): Promise<{ idToken: string; accessToken: string; refreshToken: string }> {
  await page.goto(`${clientBaseURL}/start`);
  await page.getByLabel('Username:').fill(username);
  await page.getByLabel('Password:').fill('password');
  await page.getByRole('button', { name: 'Login' }).click();
  await page.getByRole('button', { name: 'Approve' }).click();
  return {
    idToken: (await page.getByTestId('token-id-token').textContent()) ?? '',
    accessToken: (await page.getByTestId('token-access-token').textContent()) ?? '',
    refreshToken: (await page.getByTestId('token-refresh-token').textContent()) ?? '',
  };
}

async function obtainIdToken(
  page: import('@playwright/test').Page,
  username = 'testuser',
): Promise<string> {
  return (await obtainTokens(page, username)).idToken;
}

/** SSO plus the token exchange: hand back a freshly issued ID-JAG. */
async function obtainIdJag(
  page: import('@playwright/test').Page,
  request: APIRequestContext,
  idpIssuer: string,
): Promise<string> {
  const idToken = await obtainIdToken(page);
  const res = await request.post(`${idpIssuer}/token`, {
    form: {
      grant_type: EXCHANGE_GRANT_TYPE,
      requested_token_type: ID_JAG_TOKEN_TYPE,
      subject_token: idToken,
      subject_token_type: ID_TOKEN_TYPE,
      audience: xaaIssuer,
      scope: 'openid profile',
      client_id: clientId,
      client_secret: clientSecret,
    },
  });
  return ((await res.json()) as Record<string, string>).access_token ?? '';
}

/** Decode a JWT segment (base64url, RFC 7515 §2). */
function decodeJwtSegment(segment: string): Record<string, unknown> {
  const base64 = segment.replace(/-/g, '+').replace(/_/g, '/');
  const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
  return JSON.parse(atob(padded)) as Record<string, unknown>;
}

async function discovery(
  request: APIRequestContext,
  issuer: string,
): Promise<Record<string, unknown>> {
  const response = await request.get(`${issuer}/.well-known/openid-configuration`);
  return (await response.json()) as Record<string, unknown>;
}

/**
 * True only when the IdP OP advertises ID-JAG issuance AND the second OP is up
 * and advertises the grant profile. The second instance only starts for the
 * hono sample, so the reachability probe doubles as the skip condition for
 * every other sample OP.
 */
async function supportsXaa(request: APIRequestContext, idpIssuer: string): Promise<boolean> {
  try {
    const idpMetadata = await discovery(request, idpIssuer);
    const chaining = idpMetadata.identity_chaining_requested_token_types_supported;
    if (!Array.isArray(chaining) || !chaining.includes(ID_JAG_TOKEN_TYPE)) {
      return false;
    }
    const asMetadata = await discovery(request, xaaIssuer);
    const profiles = asMetadata.authorization_grant_profiles_supported;
    return Array.isArray(profiles) && profiles.includes(ID_JAG_GRANT_PROFILE);
  } catch {
    return false;
  }
}

function requireBaseUrl(baseURL: string | undefined): string {
  if (baseURL === undefined) {
    throw new Error('baseURL is not configured');
  }
  return baseURL;
}
```

## 関連資料

- 要件文書: `tasks/experimental/id-jag/specification.md`（エラー写像の全表とセキュリティ要件）、`tasks/experimental/id-jag/understanding-guide.md`（XAA の背景と誤解しやすい点）
- 一次資料の対応表: `tasks/experimental/id-jag/sources.md`
- 利用者向けドキュメント: OSS リポジトリの `docs/library-document/src/content/docs/experimental/id-jag.md`
- 既存機能の解説: [token-exchange.ja.md](./token-exchange.ja.md)（同じ grant_type URN を使う隣接機能。入力と出力の種別が異なる）
