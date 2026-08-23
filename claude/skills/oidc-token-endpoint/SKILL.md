---
name: oidc-token-endpoint
description: OpenID Connect Token Endpoint implementation guide for Basic OP certification. Use when implementing token request handling, client authentication (client_secret_basic, client_secret_post), authorization code exchange, and token response generation. Covers OpenID Connect Core 1.0 Section 3.1.3 and Section 9 requirements.
---

# OpenID Connect Token Endpoint

Implementation requirements for Token Endpoint to achieve Basic OpenID Provider certification.

## Endpoint Requirements

- MUST use TLS (HTTPS)
- MUST use HTTP POST method
- MUST support `application/x-www-form-urlencoded` content type

## Token Request (Authorization Code Exchange)

```http
POST /token HTTP/1.1
Host: server.example.com
Content-Type: application/x-www-form-urlencoded
Authorization: Basic czZCaGRSa3F0MzpnWDFmQmF0M2JW

grant_type=authorization_code
&code=SplxlOBeZQQYbYS6WxSbIA
&redirect_uri=https%3A%2F%2Fclient.example.org%2Fcb
```

### Required Parameters

| Parameter | Description |
|-----------|-------------|
| `grant_type` | MUST be `authorization_code` |
| `code` | Authorization code received from authorization endpoint |
| `redirect_uri` | REQUIRED if included in authorization request |

## Client Authentication Methods

### client_secret_basic (MUST Support)

HTTP Basic Authentication with client_id:client_secret.

```http
Authorization: Basic czZCaGRSa3F0MzpnWDFmQmF0M2JW
```

Encoding: `base64(client_id + ":" + client_secret)`

Test IDs:
- `OP-ClientAuth-Basic-Static`
- `OP-ClientAuth-Basic-Dynamic`

### client_secret_post (MUST Support)

Credentials in request body.

```http
POST /token HTTP/1.1
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
&code=SplxlOBeZQQYbYS6WxSbIA
&client_id=s6BhdRkqt3
&client_secret=gX1fBat3bV
```

Test IDs:
- `OP-ClientAuth-SecretPost-Static`
- `OP-ClientAuth-SecretPost-Dynamic`

## Token Request Validation

1. Authenticate client (confidential clients)
2. Verify authorization code is valid
3. Verify code was issued to authenticated client
4. Verify redirect_uri matches original request (if applicable)
5. Verify code has not expired
6. Verify code has not been used before

## Authorization Code Security

### Single Use Requirement

- MUST return access token only once per code
- If second request received with same code:
  - MUST deny request
  - SHOULD revoke all tokens issued for that code

Test IDs:
- `OP-OAuth-2nd`: Reject second use
- `OP-OAuth-2nd-30s`: Reject after 30 seconds (OAuth MUST)
- `OP-OAuth-2nd-Revokes`: Revoke tokens on reuse (OAuth SHOULD)

### Code Lifetime

- MUST expire shortly after issuance
- RECOMMENDED: Maximum 10 minutes

## Token Response

### Success Response

```http
HTTP/1.1 200 OK
Content-Type: application/json
Cache-Control: no-store

{
  "access_token": "SlAV32hkKG",
  "token_type": "Bearer",
  "expires_in": 3600,
  "refresh_token": "8xLOxBtZp8",
  "id_token": "eyJhbGciOiJSUzI1NiIsImtpZCI6IjFlOWdkazcifQ..."
}
```

### Required Response Parameters

| Parameter | Description |
|-----------|-------------|
| `access_token` | Access token for UserInfo Endpoint |
| `token_type` | MUST be `Bearer` |
| `id_token` | ID Token (JWT) |

### Optional Response Parameters

| Parameter | Description |
|-----------|-------------|
| `expires_in` | Access token lifetime in seconds (RECOMMENDED) |
| `refresh_token` | Refresh token (OPTIONAL) |
| `scope` | Granted scope (if different from requested) |

## Error Response

```http
HTTP/1.1 400 Bad Request
Content-Type: application/json

{
  "error": "invalid_grant",
  "error_description": "Authorization code has expired"
}
```

### Error Codes

| Error | Description |
|-------|-------------|
| `invalid_request` | Missing/invalid parameter |
| `invalid_client` | Client authentication failed |
| `invalid_grant` | Invalid/expired code |
| `unauthorized_client` | Client not authorized for grant type |
| `unsupported_grant_type` | Grant type not supported |

## Confidential vs Public Clients

### Confidential Clients
- MUST authenticate at token endpoint
- Have client_secret or other credentials

### Public Clients
- Cannot securely store credentials
- Verify code was issued to client_id in request

## Response Headers

```http
Cache-Control: no-store
Pragma: no-cache
```

MUST include to prevent caching of tokens.

## ID Token in Token Response

When returning ID Token from Token Endpoint:

- `at_hash` is OPTIONAL (but SHOULD include)
- `nonce` MUST be included if present in authentication request
- Signature REQUIRED (unless client registered `none`)

## Implementation Checklist

1. [ ] Support TLS/HTTPS only
2. [ ] Accept POST requests only
3. [ ] Support client_secret_basic authentication
4. [ ] Support client_secret_post authentication
5. [ ] Validate authorization code
6. [ ] Enforce single-use authorization codes
7. [ ] Return proper token response format
8. [ ] Include Cache-Control: no-store header
9. [ ] Return proper error responses
