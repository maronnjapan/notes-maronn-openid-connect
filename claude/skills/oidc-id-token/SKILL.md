---
name: oidc-id-token
description: OpenID Connect ID Token implementation guide for Basic OP certification. Use when implementing ID Token generation, required claims, JWT signing with RS256, nonce/at_hash/c_hash validation. Covers OpenID Connect Core 1.0 Section 2 and Section 3.1.3.6 requirements.
---

# OpenID Connect ID Token

Implementation requirements for ID Token to achieve Basic OpenID Provider certification.

## ID Token Structure

ID Token is a JWT (JSON Web Token) containing claims about authentication event.

```json
{
  "iss": "https://server.example.com",
  "sub": "248289761001",
  "aud": "s6BhdRkqt3",
  "exp": 1311281970,
  "iat": 1311280970,
  "nonce": "n-0S6_WzA2Mj",
  "auth_time": 1311280969
}
```

## Required Claims

| Claim | Description | Requirement |
|-------|-------------|-------------|
| `iss` | Issuer Identifier (HTTPS URL) | REQUIRED |
| `sub` | Subject Identifier (unique, never reassigned) | REQUIRED |
| `aud` | Audience (client_id of RP) | REQUIRED |
| `exp` | Expiration time (seconds since epoch) | REQUIRED |
| `iat` | Issued at time (seconds since epoch) | REQUIRED |

Test ID: `IdToken.verify()`

## Conditional Claims

| Claim | When Required |
|-------|---------------|
| `nonce` | If `nonce` was in authentication request |
| `auth_time` | If `max_age` was in request, or `require_auth_time` is true |
| `at_hash` | If Access Token returned from Authorization Endpoint (Implicit/Hybrid) |
| `c_hash` | If Authorization Code returned from Authorization Endpoint (Hybrid) |

## Signing Requirements

### RS256 (REQUIRED for Basic OP)

- Algorithm: RSASSA-PKCS1-v1_5 using SHA-256
- `alg` header value: `RS256`
- Test ID: `OP-IDToken-RS256`

Exception: RS256 not required if:
- ID Tokens only returned from Token Endpoint (code flow)
- AND client only registers `none` as signing algorithm

### JOSE Header

```json
{
  "alg": "RS256",
  "kid": "1e9gdk7"
}
```

| Header | Requirement | Test ID |
|--------|-------------|---------|
| `alg` | REQUIRED | `OP-IDToken-Signature` |
| `kid` | REQUIRED | `OP-IDToken-kid` |

### Unsecured JWT (`alg: none`)

- MAY support if client registers for it
- Test ID: `OP-IDToken-none`

## Hash Claims Calculation

### at_hash (Access Token Hash)

Required when: ID Token and Access Token returned from Authorization Endpoint.

```python
# Calculation
hash = SHA256(ASCII(access_token))
at_hash = base64url(hash[0:128])  # left-most 128 bits
```

Test ID: `OP-IDToken-at_hash`

### c_hash (Code Hash)

Required when: ID Token and Authorization Code returned from Authorization Endpoint (Hybrid flow).

```python
# Calculation
hash = SHA256(ASCII(code))
c_hash = base64url(hash[0:128])  # left-most 128 bits
```

Test ID: `OP-IDToken-c_hash`

### Hash Algorithm Selection

Use hash algorithm matching `alg` in JOSE header:

| alg | Hash Algorithm | Hash Bits |
|-----|----------------|-----------|
| RS256 | SHA-256 | 128 |
| RS384 | SHA-384 | 192 |
| RS512 | SHA-512 | 256 |

## Nonce Claim

- Pass through unmodified from authentication request
- MUST have sufficient entropy to prevent guessing

```json
{
  "nonce": "n-0S6_WzA2Mj"
}
```

Test IDs:
- `OP-nonce-code` (code flow)
- `OP-nonce-noncode` (implicit/hybrid)

## auth_time Claim

Time when End-User authentication occurred (seconds since epoch).

```json
{
  "auth_time": 1311280969
}
```

REQUIRED when:
- `max_age` parameter was in authentication request
- `require_auth_time` client metadata is true

## Subject Identifier Types

### Public Subject Type
- Same `sub` value for all clients
- Globally unique identifier

### Pairwise Subject Type
- Different `sub` value per client
- Prevents correlation across clients

```
sub = hash(sector_identifier + local_user_id + salt)
```

## ID Token Validation (RP Side Reference)

For OP implementation, ensure tokens can pass these validations:

1. Decode JWT and verify signature using OP's public key
2. Verify `iss` matches expected issuer
3. Verify `aud` contains client_id
4. Verify `exp` > current_time
5. Verify `iat` is reasonable
6. Verify `nonce` matches sent value (if applicable)
7. Verify `at_hash` matches access_token hash (if applicable)
8. Verify `c_hash` matches code hash (if applicable)

## Example ID Token (Decoded)

```json
{
  "iss": "https://server.example.com",
  "sub": "248289761001",
  "aud": "s6BhdRkqt3",
  "nonce": "n-0S6_WzA2Mj",
  "exp": 1311281970,
  "iat": 1311280970,
  "auth_time": 1311280969,
  "at_hash": "77QmUPtjPfzWtF2AnpK9RQ"
}
```

## Key Rotation

- Publish public keys at `jwks_uri`
- Include `kid` in ID Token header
- Support key rotation without breaking existing tokens
- Include `Cache-Control` header with `max-age` directive
