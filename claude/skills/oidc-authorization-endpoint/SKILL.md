---
name: oidc-authorization-endpoint
description: OpenID Connect Authorization Endpoint implementation guide for Basic OP certification. Use when implementing authentication request handling, response_type validation, prompt/display parameters, nonce handling, and authorization response generation. Covers OpenID Connect Core 1.0 Section 3.1.2 requirements.
---

# OpenID Connect Authorization Endpoint

Implementation requirements for Authorization Endpoint to achieve Basic OpenID Provider certification.

## Response Type Support

### Required for Basic OP

| Parameter | Value | Requirement |
|-----------|-------|-------------|
| `response_type` | `code` | MUST support |
| Missing `response_type` | - | MUST reject with error |

### Test IDs
- `OP-Response-code`: Request with response_type=code
- `OP-Response-Missing`: Reject missing response_type

## Authentication Request Parameters

### Required Parameters

```
response_type  = "code"           # REQUIRED
client_id      = <client_id>      # REQUIRED  
redirect_uri   = <uri>            # REQUIRED if multiple registered
scope          = "openid ..."     # REQUIRED (must include openid)
```

### Optional Parameters

```
state          = <opaque_value>   # RECOMMENDED
nonce          = <random_string>  # OPTIONAL for code flow
prompt         = none|login|consent|select_account
display        = page|popup|touch|wap
max_age        = <seconds>
ui_locales     = <locale_list>
claims_locales = <locale_list>
acr_values     = <acr_list>
login_hint     = <hint>
id_token_hint  = <id_token>
```

## Prompt Parameter (MUST Support)

| Value | Behavior |
|-------|----------|
| `none` | No UI displayed. If not authenticated, return `login_required` error |
| `login` | Force reauthentication even if session exists |
| `consent` | Force consent prompt even if previously granted |
| `select_account` | Prompt user to select account |

Test IDs:
- `OP-prompt-login`
- `OP-prompt-none-NotLoggedIn`
- `OP-prompt-none-LoggedIn`

## Display Parameter (MUST Support)

Minimum requirement: parameter use must not result in error.

| Value | Description |
|-------|-------------|
| `page` | Full page (default) |
| `popup` | Popup window |
| `touch` | Touch-optimized |
| `wap` | Feature phone |

Test IDs:
- `OP-display-page`
- `OP-display-popup`

## Nonce Handling

### Code Flow
- `nonce` is OPTIONAL in request
- If provided, MUST include in ID Token
- Test ID: `OP-nonce-NoReq-code`, `OP-nonce-code`

### Implicit/Hybrid Flow
- `nonce` is REQUIRED in request
- MUST reject requests without nonce
- Test ID: `OP-nonce-NoReq-noncode`, `OP-nonce-noncode`

## Max Age Parameter (MUST Support)

```
max_age = <seconds>
```

- Specifies maximum elapsed time since last active authentication
- If exceeded, MUST re-authenticate user
- When used, MUST include `auth_time` claim in ID Token

Test IDs:
- `OP-Req-max_age=1`
- `OP-Req-max_age=10000`

## Locale Parameters (MUST Support)

Minimum requirement: parameter use must not result in error.

```
ui_locales     = "ja en"    # Preferred UI languages
claims_locales = "ja en"    # Preferred claim languages
```

Test IDs:
- `OP-Req-ui_locales`
- `OP-Req-claims_locales`

## ACR Values (MUST Support)

Minimum requirement: parameter use must not result in error.

```
acr_values = "urn:mace:incommon:iap:silver"
```

Test ID: `OP-Req-acr_values`

## Additional Parameters

| Parameter | Requirement | Test ID |
|-----------|-------------|---------|
| `login_hint` | No error | `OP-Req-login_hint` |
| `id_token_hint` | SHOULD support | `OP-Req-id_token_hint` |
| Unknown params | MUST ignore | `OP-Req-NotUnderstood` |

## Authorization Response

### Success Response (Code Flow)

```
HTTP/1.1 302 Found
Location: https://client.example.org/cb?
  code=SplxlOBeZQQYbYS6WxSbIA
  &state=af0ifjsldkj
```

### Required Response Parameters

| Parameter | Requirement |
|-----------|-------------|
| `code` | REQUIRED |
| `state` | REQUIRED if present in request |

## State Parameter

- MUST return exact value received from client
- Test ID: `VerifyState()`

## Request Validation Checklist

1. Validate all OAuth 2.0 parameters
2. Verify `scope` contains `openid`
3. Verify all REQUIRED parameters present
4. Validate `redirect_uri` matches registered URI
5. If `sub` claim requested with specific value, only respond if that user is authenticated
