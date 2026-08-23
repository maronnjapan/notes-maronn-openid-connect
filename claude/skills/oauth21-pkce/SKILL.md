---
name: oauth21-pkce
description: OAuth 2.1 PKCE (Proof Key for Code Exchange) implementation guide. Use when implementing code_challenge/code_verifier validation, S256 transformation, authorization code binding, and PKCE enforcement. PKCE is REQUIRED in OAuth 2.1 for all clients. Covers OAuth 2.1 Section 4.1.1 and Section 7.5 requirements.
---

# OAuth 2.1 PKCE Implementation

PKCE is REQUIRED in OAuth 2.1 to prevent authorization code injection attacks.

## Overview

```
┌──────────┐                              ┌──────────────────┐
│          │─────(1) code_challenge ─────>│                  │
│  Client  │                              │  Authorization   │
│          │<────(2) authorization code───│     Server       │
│          │                              │                  │
│          │─────(3) code_verifier ──────>│                  │
│          │<────(4) access token ────────│                  │
└──────────┘                              └──────────────────┘
```

## Code Verifier

Client-generated cryptographic random string.

### Requirements

- Length: 43-128 characters
- Characters: `[A-Z] / [a-z] / [0-9] / "-" / "." / "_" / "~"` (unreserved)
- Entropy: SHOULD be generated from 32+ octets of random data

### ABNF

```abnf
code-verifier = 43*128unreserved
unreserved = ALPHA / DIGIT / "-" / "." / "_" / "~"
```

### Generation Example

```python
import secrets
import base64

# Generate 32 random bytes
random_bytes = secrets.token_bytes(32)

# Base64url encode (results in 43 characters)
code_verifier = base64.urlsafe_b64encode(random_bytes).rstrip(b'=').decode('ascii')
```

## Code Challenge

Derived from code_verifier using transformation method.

### S256 Method (REQUIRED to Support)

```
code_challenge = BASE64URL-ENCODE(SHA256(ASCII(code_verifier)))
```

```python
import hashlib
import base64

def generate_code_challenge(code_verifier):
    digest = hashlib.sha256(code_verifier.encode('ascii')).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b'=').decode('ascii')
```

### Plain Method (OPTIONAL)

```
code_challenge = code_verifier
```

Only used when client cannot support S256 (e.g., constrained devices).

## Authorization Request Parameters

```http
GET /authorize?
  response_type=code
  &client_id=s6BhdRkqt3
  &redirect_uri=https%3A%2F%2Fclient.example.com%2Fcb
  &code_challenge=6fdkQaPm51l13DSukcAH3Mdx7_ntecHYd1vi3n0hMZY
  &code_challenge_method=S256
  &state=xyz
```

| Parameter | Requirement |
|-----------|-------------|
| `code_challenge` | REQUIRED (unless exemption applies) |
| `code_challenge_method` | OPTIONAL, defaults to `plain` |

### code_challenge_method Values

| Value | Description |
|-------|-------------|
| `S256` | SHA-256 hash (RECOMMENDED) |
| `plain` | No transformation |

## Token Request Parameters

```http
POST /token HTTP/1.1
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
&code=SplxlOBeZQQYbYS6WxSbIA
&code_verifier=3641a2d12d66101249cdf7a79c000c1f8c05d2aafcf14bf146497bed
&client_id=s6BhdRkqt3
```

| Parameter | Requirement |
|-----------|-------------|
| `code_verifier` | REQUIRED if code_challenge was in auth request |

## Authorization Server Validation

### Authorization Request

1. Accept `code_challenge` parameter
2. Accept `code_challenge_method` parameter (default: `plain`)
3. MUST reject unsupported `code_challenge_method` with `invalid_request`
4. Associate code_challenge with issued authorization code

### Token Request

```python
def validate_code_verifier(code_verifier, stored_challenge, method):
    if method == 'S256':
        computed = base64url(sha256(code_verifier))
        return computed == stored_challenge
    elif method == 'plain':
        return code_verifier == stored_challenge
    return False
```

Validation steps:

1. Verify `code_verifier` present if `code_challenge` was in auth request
2. Compute challenge from `code_verifier` using stored method
3. Compare with stored `code_challenge`
4. Reject if mismatch

### Rejection Rules

| Condition | Action |
|-----------|--------|
| Public client without code_challenge | MUST reject |
| code_challenge present, code_verifier missing | MUST reject |
| code_verifier mismatch | MUST reject |
| Unsupported code_challenge_method | MUST reject with `invalid_request` |

## PKCE Exemption (OAuth 2.1)

PKCE enforcement MAY be skipped ONLY when BOTH conditions met:

1. Client is confidential client
2. Reasonable assurance client implements OpenID Connect nonce properly

Even when exempt, using PKCE is still RECOMMENDED.

## Security Considerations

### Code Challenge Storage

- MUST associate code_challenge with authorization code
- MAY store encrypted in code itself
- MUST NOT expose code_challenge in response parameters

### Why S256 Over Plain

- Plain method exposes code_verifier in authorization request
- Attacker reading request can defeat PKCE protection
- S256 prevents this by hashing

### Binding

Authorization code is bound to:
- client_id
- code_challenge
- redirect_uri

## Error Responses

### Missing code_challenge (Public Client)

```http
HTTP/1.1 302 Found
Location: https://client.example.com/cb?
  error=invalid_request
  &error_description=code_challenge+required
```

### Unsupported Method

```http
HTTP/1.1 302 Found
Location: https://client.example.com/cb?
  error=invalid_request
  &error_description=transform+algorithm+not+supported
```

### Invalid code_verifier

```http
HTTP/1.1 400 Bad Request
Content-Type: application/json

{
  "error": "invalid_grant",
  "error_description": "code_verifier validation failed"
}
```

## Implementation Checklist

1. [ ] Support code_challenge parameter
2. [ ] Support code_challenge_method (S256, optionally plain)
3. [ ] S256 is Mandatory to Implement (MTI)
4. [ ] Reject unsupported methods with invalid_request
5. [ ] Store code_challenge with authorization code
6. [ ] Require code_verifier in token request if code_challenge present
7. [ ] Validate code_verifier against stored challenge
8. [ ] Reject public clients without code_challenge
9. [ ] Do not expose code_challenge in response
