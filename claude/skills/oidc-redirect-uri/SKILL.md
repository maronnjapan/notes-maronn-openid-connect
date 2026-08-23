---
name: oidc-redirect-uri
description: OpenID Connect Redirect URI validation guide for Basic OP certification. Use when implementing redirect URI registration, validation, exact matching, query parameter handling, and fragment rejection. Covers OpenID Connect Core 1.0 and OAuth 2.1 redirect URI requirements.
---

# OpenID Connect Redirect URI Validation

Implementation requirements for Redirect URI handling to achieve Basic OpenID Provider certification.

## Registration Requirements

### Complete URI Registration

- Clients MUST register complete redirect URIs
- Include path component
- Authorization servers MUST require registration

### Multiple URIs

- MAY allow multiple redirect URIs per client
- If multiple registered, `redirect_uri` parameter is REQUIRED in request

Test ID: `OP-redirect_uri-Missing`

## Validation Rules

### Exact String Matching (REQUIRED)

Compare URIs using RFC 3986 Section 6.2.1 Simple String Comparison.

```python
def validate_redirect_uri(request_uri, registered_uris):
    # Exact string match required
    return request_uri in registered_uris
```

Test ID: `OP-redirect_uri-NotReg`

### Reject Unregistered URIs

```http
HTTP/1.1 400 Bad Request

{
  "error": "invalid_request",
  "error_description": "redirect_uri not registered"
}
```

MUST NOT redirect to unregistered URI.

## Query Parameter Handling

### Preserve Registered Query Parameters

If registered URI has query parameters, request URI MUST have same parameters.

```
Registered: https://client.example.org/cb?mode=auth
Request:    https://client.example.org/cb?mode=auth  ✓ Valid
Request:    https://client.example.org/cb            ✗ Invalid
```

Test ID: `OP-redirect_uri-Query-OK`

### Reject Mismatched Query Parameters

```
Registered: https://client.example.org/cb?mode=auth
Request:    https://client.example.org/cb?mode=other  ✗ Invalid
```

Test ID: `OP-redirect_uri-Query-Mismatch`

### Reject Added Query Parameters

```
Registered: https://client.example.org/cb
Request:    https://client.example.org/cb?extra=param  ✗ Invalid
```

Test ID: `OP-redirect_uri-Query-Added`

## Fragment Handling

### Reject Fragment in Registration

- MUST NOT allow fragment component in registered URIs
- Reject registration attempts with fragments

```
Attempt:    https://client.example.org/cb#fragment  ✗ Reject
```

Test ID: `OP-redirect_uri-RegFrag`

### Handling Existing Fragments

- User-agent replaces existing fragment with authorization response
- Per RFC 6749 Section 4.2.2

## Localhost/Loopback Exception (OAuth 2.1)

For native apps using loopback URIs:

- Allow variable port numbers
- Compare scheme, host, and path only

```
Registered: http://127.0.0.1/callback
Request:    http://127.0.0.1:8080/callback  ✓ Valid (different port OK)
Request:    http://127.0.0.1:9000/callback  ✓ Valid (different port OK)
```

Valid loopback hosts:
- `localhost`
- `127.0.0.1`
- `[::1]`

## HTTPS Requirement

### Standard URIs
- MUST use `https` scheme

### Exceptions
- Native apps MAY use `http` with localhost/loopback
- Custom URI schemes for native apps

## Error Handling

### Invalid redirect_uri

When redirect_uri is invalid or missing:

1. MUST NOT redirect user-agent
2. MUST inform resource owner of error
3. SHOULD display error to user

```http
HTTP/1.1 400 Bad Request
Content-Type: text/html

<html>
<body>
  <h1>Error</h1>
  <p>Invalid redirect URI</p>
</body>
</html>
```

### Client Identifier Invalid

Same handling as invalid redirect_uri:
- Do not redirect
- Display error to user

## Security Considerations

### Open Redirector Prevention

- Validate redirect_uri against registered URIs
- Do not use redirect_uri from request without validation

### URI Matching Attacks

- Use exact string comparison
- Do not normalize URIs before comparison
- Reject partial matches

## Implementation Checklist

1. [ ] Require redirect URI registration
2. [ ] Use exact string comparison
3. [ ] Reject unregistered URIs without redirect
4. [ ] Require redirect_uri if multiple registered
5. [ ] Preserve query parameters in comparison
6. [ ] Reject mismatched query parameters
7. [ ] Reject added query parameters
8. [ ] Reject fragments in registration
9. [ ] Allow localhost port variation (native apps)
10. [ ] Require HTTPS (except loopback)
11. [ ] Display errors without redirecting on invalid URI
