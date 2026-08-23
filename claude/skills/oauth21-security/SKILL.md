---
name: oauth21-security
description: OAuth 2.1 security requirements and best practices. Use when implementing TLS requirements, HTTP redirect handling, removed grant types, sender-constrained tokens, and security considerations. Covers OAuth 2.1 Section 1.5, Section 7, and Section 10 requirements.
---

# OAuth 2.1 Security Requirements

Security requirements and removed features in OAuth 2.1.

## TLS Requirements

### All Endpoints MUST Use HTTPS

| Endpoint | Requirement |
|----------|-------------|
| Authorization Endpoint | HTTPS required |
| Token Endpoint | HTTPS required |
| Resource Endpoints | HTTPS required |
| Redirect URIs | HTTPS required* |

*Exception: Loopback URIs may use HTTP

### Loopback Exception

Native apps may use HTTP with:
- `localhost`
- `127.0.0.1`
- `[::1]`

### TLS Version

- TLS 1.3 recommended (current at time of OAuth 2.1)
- Follow BCP 195 for TLS recommendations

### Certificate Validation

- MUST validate TLS certificate chains per RFC 9110 Section 4.3.4
- Prevents DNS hijacking attacks

## HTTP Redirect Requirements

### Prohibited: HTTP 307

- MUST NOT use 307 status for redirects containing user credentials
- 307 preserves request method and body → credential exposure risk

### Recommended: HTTP 303

- SHOULD use 303 ("See Other") for such redirects
- 303 always uses GET for redirect

### Allowed

- 302 Found (common)
- 303 See Other (recommended)
- JavaScript redirect
- Meta refresh

## Removed Grant Types

### Implicit Grant (REMOVED)

```http
# NO LONGER IN OAuth 2.1
response_type=token   ✗ REMOVED
```

#### Why Removed

- Access tokens in URL fragment vulnerable to leakage
- Cannot be sender-constrained
- Browser history, referrer headers expose tokens
- No way to verify token was issued to client

#### Alternative

Use Authorization Code Flow with PKCE, even for browser-based apps.

### Resource Owner Password Credentials (REMOVED)

```http
# NO LONGER IN OAuth 2.1
grant_type=password   ✗ REMOVED
```

#### Why Removed

- Exposes user credentials to client
- Cannot support MFA, passwordless
- Undermines OAuth security model

#### Alternative

Use standard authorization flows with user-agent.

## PKCE (REQUIRED)

PKCE is no longer optional in OAuth 2.1.

### Client Requirements

- All clients MUST use code_challenge and code_verifier
- S256 method required when client supports it

### Server Requirements

- MUST support code_challenge parameter
- MUST enforce PKCE for public clients
- SHOULD enforce for confidential clients

### Exemption

PKCE may be skipped only when BOTH:
1. Client is confidential
2. Client properly implements OpenID Connect nonce

Even when exempt, PKCE is RECOMMENDED.

## Sender-Constrained Tokens (RECOMMENDED)

Bind tokens to specific sender.

### DPoP (RFC 9449)

```http
GET /resource HTTP/1.1
Authorization: DPoP eyJhbGciOiJSUzI1NiJ9...
DPoP: eyJhbGciOiJFUzI1NiIsInR5cCI6ImRwb3Arand0In0...
```

- Client proves possession of private key
- Token bound to client's key

### Mutual TLS (RFC 8705)

- Client certificate presented during TLS
- Token bound to certificate thumbprint

### Benefits

- Stolen tokens unusable without private key
- Prevents token replay attacks
- Stronger security for sensitive resources

## Authorization Code Security

### Code Lifetime

- MUST expire shortly after issuance
- RECOMMENDED: Maximum 10 minutes

### Single Use

- MUST return access token only once per code
- Second use MUST be rejected
- SHOULD revoke all tokens from reused code

### Replay Detection

```python
def handle_token_request(code, code_verifier):
    if code.already_used:
        revoke_tokens_issued_for(code)
        return error("invalid_grant")
    
    if not validate_pkce(code, code_verifier):
        # Invalid code_verifier - possible injection
        return error("invalid_grant")
    
    mark_as_used(code)
    return issue_tokens(code)
```

### Code Binding

Authorization code bound to:
- client_id
- redirect_uri
- code_challenge

## Mix-Up Attack Prevention

### Problem

Client interacts with multiple authorization servers and can be tricked into sending code to wrong server.

### Solution: Issuer Identifier

Authorization response MAY include `iss` parameter:

```http
HTTP/1.1 302 Found
Location: https://client.example.com/cb?
  code=SplxlOBeZQQYbYS6WxSbIA
  &state=xyz
  &iss=https%3A%2F%2Fauthorization-server.example.com
```

Client validates `iss` matches expected authorization server.

See RFC 9207 for details.

## Bearer Token Security

### Prohibited

- Query parameter transmission
- Storage in cookies (unless properly secured)
- Logging

### Required

- TLS for transmission
- Certificate validation
- Short lifetimes for browser environments

### Recommended

- Audience restriction
- Minimum scope

## CSRF Protection

### Authorization Request

- code_challenge provides CSRF protection
- State parameter as additional layer

### Redirect Endpoint

- Validate state matches sent value
- code_challenge/code_verifier prevents code injection

## Open Redirector Prevention

- Validate redirect_uri against registered URIs
- Reject unregistered URIs
- Do not allow arbitrary redirects

## Comparison with OAuth 2.0

| Feature | OAuth 2.0 | OAuth 2.1 |
|---------|-----------|-----------|
| PKCE | Extension (RFC 7636) | REQUIRED |
| Implicit grant | Defined | REMOVED |
| Password grant | Defined | REMOVED |
| Query token | Discouraged | PROHIBITED |
| redirect_uri matching | Flexible | Exact match |
| Refresh token (public) | No constraint | Sender-constrained or rotation |

## Implementation Checklist

### Authorization Server

1. [ ] Use TLS for all endpoints
2. [ ] Support PKCE (S256 required)
3. [ ] Enforce PKCE for public clients
4. [ ] Do not implement implicit grant
5. [ ] Do not implement password grant
6. [ ] Enforce exact redirect_uri matching
7. [ ] Short authorization code lifetime
8. [ ] Enforce single-use authorization codes
9. [ ] Use 303 for credential-containing redirects
10. [ ] Consider issuer identifier in response
11. [ ] Support sender-constrained tokens
12. [ ] Validate TLS certificates

### Client

1. [ ] Use TLS for all requests
2. [ ] Implement PKCE (prefer S256)
3. [ ] Do not use implicit flow
4. [ ] Do not send tokens in query parameters
5. [ ] Validate state parameter
6. [ ] Validate issuer identifier if present
7. [ ] Use sender-constrained tokens if available
