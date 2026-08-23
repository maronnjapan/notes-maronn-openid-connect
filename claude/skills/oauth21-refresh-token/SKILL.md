---
name: oauth21-refresh-token
description: OAuth 2.1 Refresh Token implementation guide. Use when implementing refresh token issuance, rotation, binding, public client constraints, and sender-constrained tokens. Covers OAuth 2.1 Section 4.3 requirements.
---

# OAuth 2.1 Refresh Token

Refresh Token requirements specific to OAuth 2.1.

## Refresh Token Overview

Refresh tokens are long-lived credentials used to obtain new access tokens without user interaction.

```
┌──────────┐                              ┌──────────────────┐
│          │────(1) refresh_token ───────>│                  │
│  Client  │                              │  Authorization   │
│          │<───(2) new access_token ─────│     Server       │
│          │    (optionally new refresh)  │                  │
└──────────┘                              └──────────────────┘
```

## Issuance Decision

Authorization servers decide whether to issue refresh tokens based on:

- Client type (confidential vs public)
- Risk assessment
- Authorization server policy
- Grant sensitivity

If not issued, clients must restart OAuth flow for new tokens.

## Security Requirements

### Confidentiality

- MUST keep refresh tokens confidential in transit and storage
- Only share between authorization server and issued client

### Client Binding

- MUST maintain binding between refresh token and client
- MUST verify binding when client identity can be authenticated

### Scope/Resource Binding

- MUST bind to scope and resource servers consented by user
- Prevents privilege escalation
- Reduces impact of leakage

### Unpredictability

- MUST NOT be guessable or generatable by unauthorized parties

## Public Client Requirements

For public clients (cannot securely store credentials):

### Option 1: Sender-Constrained Tokens

Bind refresh token to cryptographic proof of client.

#### DPoP Binding

```http
POST /token HTTP/1.1
Content-Type: application/x-www-form-urlencoded
DPoP: eyJhbGciOiJFUzI1NiIsInR5cCI6ImRwb3Arand0In0...

grant_type=refresh_token
&refresh_token=tGzv3JOkF0XG5Qx2TlKWIA
&client_id=s6BhdRkqt3
```

#### mTLS Binding

Client certificate bound to token during TLS handshake.

### Option 2: Refresh Token Rotation

Issue new refresh token with each use, invalidate old one.

```python
def handle_refresh_request(old_refresh_token):
    if not validate_refresh_token(old_refresh_token):
        return error("invalid_grant")
    
    # Issue new tokens
    access_token = generate_access_token()
    new_refresh_token = generate_refresh_token()
    
    # Invalidate old refresh token
    invalidate(old_refresh_token)
    
    return {
        "access_token": access_token,
        "refresh_token": new_refresh_token,
        "token_type": "Bearer"
    }
```

## Confidential Client Requirements

### Client Authentication

- MUST authenticate with authorization server
- Uses same method as token endpoint

```http
POST /token HTTP/1.1
Authorization: Basic czZCaGRSa3F0MzpnWDFmQmF0M2JW
Content-Type: application/x-www-form-urlencoded

grant_type=refresh_token
&refresh_token=tGzv3JOkF0XG5Qx2TlKWIA
```

### Authentication Benefits

- Stronger binding than rotation
- Can disable client or change credentials
- Credential rotation easier than token revocation

## Refresh Token Request

### Request Parameters

| Parameter | Requirement | Description |
|-----------|-------------|-------------|
| `grant_type` | REQUIRED | Value: `refresh_token` |
| `refresh_token` | REQUIRED | The refresh token |
| `scope` | OPTIONAL | Requested scope (must not exceed original) |
| `client_id` | REQUIRED* | If not authenticating otherwise |

*Required for public clients

### Example Request

```http
POST /token HTTP/1.1
Host: server.example.com
Authorization: Basic czZCaGRSa3F0MzpnWDFmQmF0M2JW
Content-Type: application/x-www-form-urlencoded

grant_type=refresh_token
&refresh_token=tGzv3JOkF0XG5Qx2TlKWIA
&scope=openid profile
```

## Refresh Token Response

### Success Response

```http
HTTP/1.1 200 OK
Content-Type: application/json
Cache-Control: no-store

{
  "access_token": "TlBN45jURg",
  "token_type": "Bearer",
  "expires_in": 3600,
  "refresh_token": "9yNOxJtZa5",
  "scope": "openid profile"
}
```

### Response Parameters

| Parameter | Requirement |
|-----------|-------------|
| `access_token` | REQUIRED |
| `token_type` | REQUIRED |
| `expires_in` | RECOMMENDED |
| `refresh_token` | OPTIONAL (new token if rotating) |
| `scope` | REQUIRED if different from request |

## Scope Handling

### Scope Reduction

Client may request reduced scope:

```http
# Original grant: "openid profile email"
# Refresh request: "openid profile" (reduced)

grant_type=refresh_token
&refresh_token=tGzv3JOkF0XG5Qx2TlKWIA
&scope=openid%20profile
```

### Scope Expansion Prohibited

Cannot request scope beyond original grant:

```http
# Original grant: "openid profile"
# Refresh request: "openid profile admin"  ✗ INVALID

→ error: "invalid_scope"
```

## Error Responses

### Invalid Refresh Token

```http
HTTP/1.1 400 Bad Request
Content-Type: application/json

{
  "error": "invalid_grant",
  "error_description": "Refresh token is invalid or expired"
}
```

### Invalid Scope

```http
HTTP/1.1 400 Bad Request
Content-Type: application/json

{
  "error": "invalid_scope",
  "error_description": "Requested scope exceeds original grant"
}
```

## Token Lifetime

### No Standardized Communication

- No requirement to communicate refresh token lifetime
- Client cannot predict expiration
- Authorization server may revoke at any time

### Lifetime Strategies

| Strategy | Description |
|----------|-------------|
| Fixed | Static lifetime (e.g., 30 days) |
| Sliding | Extended on each use (e.g., +7 days per use) |
| Absolute | Fixed expiration regardless of use |

### Client Handling

Client must handle expired/revoked tokens:
1. Receive `invalid_grant` error
2. Restart OAuth flow from beginning

## Revocation

### Server-Initiated

- User revokes application access
- Security incident
- Policy violation

### Rotation-Based

When using rotation:
- Old token invalidated on use
- If old token reused → likely stolen
- May revoke all tokens for that grant

## Implementation Checklist

### Authorization Server

1. [ ] Decide issuance policy per client/grant
2. [ ] Bind tokens to issued client
3. [ ] Bind tokens to granted scope/resources
4. [ ] Require client authentication for confidential clients
5. [ ] Implement sender-constraint OR rotation for public clients
6. [ ] Verify binding on refresh request
7. [ ] Validate scope does not exceed original
8. [ ] Include Cache-Control: no-store
9. [ ] Handle token revocation

### Public Client Handling

1. [ ] Choose: sender-constrained OR rotation
2. [ ] If rotation: invalidate old token on use
3. [ ] If rotation: detect reuse as compromise
4. [ ] Store new refresh token on each response
