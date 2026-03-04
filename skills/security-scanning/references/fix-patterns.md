# Common Security Vulnerability Fix Patterns

This reference documents remediation patterns for common security findings from code-guardian scanners.

## SAST — Code-Level Remediation

### SQL Injection
**Remediation**: Always use parameterized queries / prepared statements.
```python
# Parameterized query prevents SQL injection
cursor.execute("SELECT * FROM users WHERE id = %s", (user_id,))
```

### Cross-Site Scripting (XSS)
**Remediation**: Use textContent for plain text output. For HTML content, use a sanitizer library like DOMPurify before rendering.

### Command Injection
**Remediation**: Use array-based subprocess invocation to avoid shell interpretation.
```python
# Array-based invocation prevents command injection
subprocess.run(["ls", user_path], check=True)
```

### Path Traversal
**Remediation**: Resolve the real path and verify it stays within the allowed base directory.
```python
resolved = os.path.realpath(os.path.join(base_dir, user_filename))
if not resolved.startswith(os.path.realpath(base_dir)):
    raise ValueError("Path traversal detected")
```

### Insecure Cryptography
**Remediation**: Use bcrypt/argon2 for passwords, SHA-256+ for hashing, AES-GCM for encryption.

### Hardcoded Secrets
**Remediation**: Move to environment variables, secret managers, or .env files (gitignored).
```python
API_KEY = os.environ["API_KEY"]
```

### Insecure Deserialization
**Remediation**: Use safe serialization formats (JSON, MessagePack) for untrusted input. Validate before deserializing.

### SSRF (Server-Side Request Forgery)
**Remediation**: Validate URL hostname against an allowlist. Block requests to internal/private IP ranges.

## Dependency Vulnerabilities

### Version Bumps
1. Check the finding's `autoFixable` field
2. If fixable: run the package manager's fix command (npm audit fix, pip-audit --fix)
3. If not: manually update the version constraint in the manifest file
4. Verify the update doesn't break compatibility

### By Package Manager
- **npm**: Update version in `package.json`, run `npm install`
- **pip**: Update version in `requirements.txt` or `pyproject.toml`
- **cargo**: Update version in `Cargo.toml`, run `cargo update`
- **bundler**: Update version in `Gemfile`, run `bundle update <gem>`
- **go**: Run `go get package@version`, then `go mod tidy`

## Container Security

### Dockerfile Best Practices
- Use specific image version tags instead of `:latest`
- Run as non-root user (`USER app`)
- Use slim/distroless base images
- Minimize installed packages (`--no-install-recommends`)
- Clean up package manager cache
- Don't store secrets in image layers

### Trivy Image Findings
1. Update the base image to latest patch version
2. Or use a distroless/slim variant
3. Rebuild the image after updating

## PHP Static Analysis (PHPStan)

### Type Safety
- **Undefined variables**: Initialize variables before use, or add null checks
- **Wrong parameter types**: Fix type signatures or add proper type casting
- **Missing return types**: Add explicit return type declarations to methods

### Security-Relevant Patterns
- **Dynamic code execution**: Replace with specific, safe alternatives
- **`unserialize()` on untrusted input**: Use `json_decode()` instead, or restrict allowed classes with `['allowed_classes' => false]`
- **`extract()` on user input**: Avoid; use explicit variable assignment instead
- **`file_get_contents()` with user input**: Validate URL/path against an allowlist
- **`preg_replace` with `/e` modifier**: Use `preg_replace_callback()` instead
- **Dynamic `include`/`require`**: Use a whitelist of allowed file paths

### Dependency Fixes (OSV-Scanner)
OSV-Scanner reports vulnerabilities from the OSV database across all ecosystems:
- **npm**: Same as npm audit — update `package.json`, run `npm install`
- **pip**: Update `requirements.txt` or `pyproject.toml`
- **composer**: Update `composer.json`, run `composer update <package>`
- **go**: `go get package@version && go mod tidy`
- **cargo/bundler**: Same as existing cargo-audit/bundler-audit patterns

## IaC Security

### Terraform
- **Unencrypted storage**: Add `encryption_configuration` block
- **Public access**: Set `publicly_accessible = false`
- **Missing logging**: Add `logging` block
- **Overly permissive IAM**: Restrict to specific actions and resources

### Kubernetes
- **Privileged containers**: Set `securityContext.privileged: false`
- **Missing resource limits**: Add `resources.limits`
- **Running as root**: Add `securityContext.runAsNonRoot: true`
- **Missing network policies**: Create NetworkPolicy resources
