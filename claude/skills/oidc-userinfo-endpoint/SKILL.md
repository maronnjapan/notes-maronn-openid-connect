---
name: oidc-userinfo-endpoint
description: OpenID Connect UserInfo Endpoint implementation guide for Basic OP certification. Use when implementing UserInfo Endpoint, access token validation, standard claims (sub, profile, email, address, phone), and scope-based claim filtering. Covers OpenID Connect Core 1.0 Section 5.3 requirements.
---

# OpenID Connect UserInfo Endpoint

Implementation requirements for UserInfo Endpoint to achieve Basic OpenID Provider certification.

## Endpoint Requirements

- MUST use TLS (HTTPS)
- MUST support Bearer token authentication
- MUST return `sub` claim
- `sub` MUST match ID Token's `sub`

Test ID: `OP-UserInfo-Endpoint`

## Access Token Transmission Methods

### Authorization Header (MUST Support)

```http
GET /userinfo HTTP/1.1
Host: server.example.com
Authorization: Bearer SlAV32hkKG
```

Test ID: `OP-UserInfo-Header`

### POST with Authorization Header

```http
POST /userinfo HTTP/1.1
Host: server.example.com
Authorization: Bearer SlAV32hkKG
```

### Form-Encoded Body (Warning if Broken)

```http
POST /userinfo HTTP/1.1
Host: server.example.com
Content-Type: application/x-www-form-urlencoded

access_token=SlAV32hkKG
```

Test ID: `OP-UserInfo-Body`

### Query Parameter (MUST NOT Support)

- MUST NOT accept access token in URI query parameter
- Security risk: tokens may be logged

## UserInfo Response

### JSON Response (Default)

```http
HTTP/1.1 200 OK
Content-Type: application/json

{
  "sub": "248289761001",
  "name": "Jane Doe",
  "given_name": "Jane",
  "family_name": "Doe",
  "email": "janedoe@example.com",
  "email_verified": true,
  "picture": "https://example.com/janedoe/me.jpg"
}
```

### Signed Response (RS256)

```http
HTTP/1.1 200 OK
Content-Type: application/jwt

eyJhbGciOiJSUzI1NiIsImtpZCI6IjFlOWdkazcifQ...
```

Test ID: `OP-UserInfo-RS256`

## Required Claims

| Claim | Requirement |
|-------|-------------|
| `sub` | REQUIRED, MUST match ID Token |

Test ID: `OpenIDSchema.verify()`

## Standard Claims by Scope

### openid Scope

```json
{
  "sub": "248289761001"
}
```

### profile Scope

```json
{
  "name": "Jane Doe",
  "family_name": "Doe",
  "given_name": "Jane",
  "middle_name": "Marie",
  "nickname": "JD",
  "preferred_username": "j.doe",
  "profile": "https://example.com/janedoe",
  "picture": "https://example.com/janedoe/me.jpg",
  "website": "https://janedoe.example.com",
  "gender": "female",
  "birthdate": "1990-10-31",
  "zoneinfo": "America/Los_Angeles",
  "locale": "en-US",
  "updated_at": 1311280970
}
```

Test ID: `OP-scope-profile`

### email Scope

```json
{
  "email": "janedoe@example.com",
  "email_verified": true
}
```

Test ID: `OP-scope-email`

### address Scope

```json
{
  "address": {
    "formatted": "123 Main St\nAnytown, CA 12345\nUSA",
    "street_address": "123 Main St",
    "locality": "Anytown",
    "region": "CA",
    "postal_code": "12345",
    "country": "USA"
  }
}
```

Test ID: `OP-scope-address`

### phone Scope

```json
{
  "phone_number": "+1 (555) 555-5555",
  "phone_number_verified": true
}
```

Test ID: `OP-scope-phone`

## Scope Test Requirements

All scope tests check for "no error" - claims may be empty if user has no data.

| Scope | Test ID | Requirement |
|-------|---------|-------------|
| openid | `OP-IDToken-Signature` | MUST support |
| profile | `OP-scope-profile` | No error |
| email | `OP-scope-email` | No error |
| address | `OP-scope-address` | No error |
| phone | `OP-scope-phone` | No error |
| all | `OP-scope-All` | No error |

## Claims Request Parameter

Support individual claim requests via `claims` parameter.

```json
{
  "userinfo": {
    "given_name": {"essential": true},
    "nickname": null,
    "email": {"essential": true}
  }
}
```

Test ID: `OP-claims-essential`

### Essential Claims

- `essential: true` indicates claim is critical
- OP SHOULD return claim if available
- Not returning essential claim is not an error

## Error Responses

### Invalid Token

```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer error="invalid_token",
  error_description="The access token expired"
```

### Insufficient Scope

```http
HTTP/1.1 403 Forbidden
WWW-Authenticate: Bearer error="insufficient_scope",
  scope="openid profile"
```

## Subject Identifier Consistency

The `sub` claim MUST be:
- Identical to `sub` in ID Token
- Locally unique and never reassigned
- Consistent across requests for same user

## Implementation Checklist

1. [ ] Support TLS/HTTPS only
2. [ ] Accept Authorization: Bearer header
3. [ ] Accept POST with bearer body
4. [ ] Return `sub` claim always
5. [ ] Match `sub` with ID Token
6. [ ] Support profile scope claims
7. [ ] Support email scope claims
8. [ ] Support address scope claims
9. [ ] Support phone scope claims
10. [ ] Handle claims request parameter
11. [ ] Return proper error responses
