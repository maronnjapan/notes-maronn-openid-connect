---
name: oidc-basic-op-certification
description: OpenID Connect Basic OP Certification complete checklist. Use when preparing for OpenID Foundation certification testing, verifying all Basic OP requirements are met, or understanding the full scope of Basic OP compliance. Covers all OpenID Connect Conformance Profiles v3.0 Basic OP test requirements.
---

# OpenID Connect Basic OP Certification

Complete checklist for Basic OpenID Provider certification based on OpenID Connect Conformance Profiles v3.0.

## Certification Overview

Basic OP certification tests implementation of:
- OpenID Connect Core 1.0 Section 3.1 (Authorization Code Flow)
- Section 15.1 (Mandatory to Implement Features for All OPs)

## Test Categories

### 1. Response Type & Response Mode

| Test ID | Requirement | Status |
|---------|-------------|--------|
| `OP-Response-code` | Support `response_type=code` | Required |
| `OP-Response-Missing` | Reject missing response_type | Required |

### 2. ID Token

| Test ID | Requirement | Status |
|---------|-------------|--------|
| `IdToken.verify()` | ID Token has iss, sub, aud, iat claims | Required |
| `OP-IDToken-Signature` | ID Token is signed | Required |
| `OP-IDToken-RS256` | Support RS256 signing | Required |
| `OP-IDToken-kid` | ID Token has kid header | Required |
| `OP-IDToken-none` | Support unsigned if registered | If uses none |

### 3. UserInfo Endpoint

| Test ID | Requirement | Status |
|---------|-------------|--------|
| `OP-UserInfo-Endpoint` | UserInfo Endpoint exists | Required |
| `OP-UserInfo-Header` | Support Authorization header | Required |
| `OP-UserInfo-Body` | Support form body | Warning |
| `OpenIDSchema.verify()` | UserInfo has sub claim | Required |
| `OP-UserInfo-RS256` | Support signed response | Required |

### 4. Nonce Parameter

| Test ID | Requirement | Status |
|---------|-------------|--------|
| `OP-nonce-NoReq-code` | Accept code flow without nonce | Required |
| `OP-nonce-code` | Return nonce in ID Token when requested | Required |

### 5. Scope Parameter

| Test ID | Requirement | Status |
|---------|-------------|--------|
| `OP-IDToken-Signature` | Support openid scope | Required |
| `OP-scope-profile` | Support profile scope | No error |
| `OP-scope-email` | Support email scope | No error |
| `OP-scope-address` | Support address scope | No error |
| `OP-scope-phone` | Support phone scope | No error |
| `OP-scope-All` | Support all scopes together | No error |

### 6. Display Parameter

| Test ID | Requirement | Status |
|---------|-------------|--------|
| `OP-display-page` | Support display=page | No error |
| `OP-display-popup` | Support display=popup | No error |

### 7. Prompt Parameter

| Test ID | Requirement | Status |
|---------|-------------|--------|
| `OP-prompt-login` | Support prompt=login | Required |
| `OP-prompt-none-NotLoggedIn` | Return error when not logged in | Required |
| `OP-prompt-none-LoggedIn` | Continue without UI when logged in | Required |

### 8. Misc Request Parameters

| Test ID | Requirement | Status |
|---------|-------------|--------|
| `OP-Req-max_age=1` | Support max_age, return auth_time | Required |
| `OP-Req-max_age=10000` | Handle large max_age | Required |
| `OP-Req-NotUnderstood` | Ignore unknown parameters | Required |
| `OP-Req-login_hint` | Support login_hint | No error |
| `OP-Req-ui_locales` | Support ui_locales | No error |
| `OP-Req-claims_locales` | Support claims_locales | No error |
| `OP-Req-acr_values` | Support acr_values | No error |
| `OP-Req-id_token_hint` | Support id_token_hint | SHOULD |

### 9. OAuth Behaviors

| Test ID | Requirement | Status |
|---------|-------------|--------|
| `VerifyState()` | Return state in response | Required |
| `OP-OAuth-2nd` | Detect code reuse | Warning <30s |
| `OP-OAuth-2nd-30s` | Reject code after 30s | OAuth MUST |
| `OP-OAuth-2nd-Revokes` | Revoke tokens on reuse | OAuth SHOULD |

### 10. Redirect URI

| Test ID | Requirement | Status |
|---------|-------------|--------|
| `OP-redirect_uri-NotReg` | Reject unregistered URI | Required |
| `OP-redirect_uri-Missing` | Require if multiple registered | Required |
| `OP-redirect_uri-Query-OK` | Preserve query parameters | Required |
| `OP-redirect_uri-Query-Mismatch` | Reject mismatched query | Required |
| `OP-redirect_uri-Query-Added` | Reject added query | Required |
| `OP-redirect_uri-RegFrag` | Reject fragment in registration | Required |

### 11. Client Authentication

| Test ID | Requirement | Status |
|---------|-------------|--------|
| `OP-ClientAuth-Basic-Static` | Support client_secret_basic | Required |
| `OP-ClientAuth-SecretPost-Static` | Support client_secret_post | Required |

### 12. Claims Request

| Test ID | Requirement | Status |
|---------|-------------|--------|
| `OP-claims-essential` | Support claims parameter | No error |

## Section 15.1 Mandatory Features

These features are MUST implement per OpenID Connect Core 1.0:

### Signing ID Tokens with RS256

OPs MUST support RS256 unless:
- Only returns ID Tokens from Token Endpoint
- AND clients only register for `alg: none`

### Prompt Parameter

MUST support with UI behaviors:
- `none` - No UI, error if auth needed
- `login` - Force reauthentication

### Display Parameter

MUST support (minimum: no error on use)

### Preferred Locales

MUST support (minimum: no error on use):
- `ui_locales`
- `claims_locales`

### Authentication Time

MUST return `auth_time` when:
- `max_age` in request
- Client registered with `require_auth_time: true`

### Maximum Authentication Age

MUST enforce `max_age` parameter

### ACR Values

MUST support `acr_values` (minimum: no error on use)

## Quick Reference: Test Count

| Category | Tests | Required | Warning/Should |
|----------|-------|----------|----------------|
| Response Type | 2 | 2 | 0 |
| ID Token | 5 | 4 | 1 |
| UserInfo | 5 | 4 | 1 |
| Nonce | 2 | 2 | 0 |
| Scope | 6 | 1 | 5 |
| Display | 2 | 0 | 2 |
| Prompt | 3 | 3 | 0 |
| Misc Params | 8 | 4 | 4 |
| OAuth | 4 | 1 | 3 |
| Redirect URI | 6 | 6 | 0 |
| Client Auth | 2 | 2 | 0 |
| Claims | 1 | 0 | 1 |
| **Total** | **46** | **29** | **17** |

## Pre-Certification Checklist

### Endpoints

- [ ] Authorization Endpoint (HTTPS)
- [ ] Token Endpoint (HTTPS)
- [ ] UserInfo Endpoint (HTTPS)
- [ ] JWKS Endpoint (for RS256 keys)

### Flows

- [ ] Authorization Code Flow complete
- [ ] Token exchange working
- [ ] UserInfo accessible

### Security

- [ ] TLS on all endpoints
- [ ] RS256 signing configured
- [ ] Public keys published

### Configuration

- [ ] Client registered with redirect_uri
- [ ] Client credentials configured
- [ ] Scopes configured

## Testing Resources

- Test Suite: https://op.certification.openid.net/
- Documentation: https://openid.net/certification/
- Profiles: OpenID Connect Conformance Profiles v3.0

## Related Skills

- `oidc-authorization-endpoint` - Detailed auth endpoint requirements
- `oidc-token-endpoint` - Token endpoint implementation
- `oidc-id-token` - ID Token requirements
- `oidc-userinfo-endpoint` - UserInfo requirements
- `oidc-redirect-uri` - Redirect URI validation
