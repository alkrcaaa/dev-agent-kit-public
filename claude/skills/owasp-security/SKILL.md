---
name: owasp-security
description: Security review, vulnerability audit and hardening — auth, sessions, input validation, injection, XSS, SSRF, crypto, secrets, access control, LLM/agent security (OWASP Top 10, ASVS, LLM/Agentic Top 10). Use before writing or reviewing security-sensitive code.
---

# OWASP Security

<!-- gate:begin -->
**Non-negotiables for auth / session / access-control code.** Every box is a defect if unticked — not a nice-to-have.

Passwords & crypto
- Argon2id, scrypt or bcrypt with a per-user random salt. Never MD5/SHA1/unsalted SHA256.
- Compare secrets with a constant-time compare, never `==`.
- Minimum length 12 (ASVS 5.0 L1), checked against a breached-password list where feasible.

Sessions
- Token ≥128 bits of entropy; if it is signed rather than random, sign with HMAC and verify before use.
- The signing key MUST come from config/env and **fail loudly when unset** — never fall back to a per-process random key (silently kills every session on restart and across workers).
- Cookie: `HttpOnly`, `SameSite=Lax` (or `Strict`), `Secure` in production.
- Expiry enforced server-side; invalidated on logout.

Access control (A01 — the most common real finding)
- Deny by default; authorization checked on **every** request, server-side.
- Every object fetched by an id from the request re-verifies ownership before read *and* before write. "The list query filters by user" is not ownership enforcement on the detail/update/delete route.

Input & injection (A05)
- Parameterized queries everywhere; never string-concatenate SQL/shell. `subprocess.run([...], shell=False)`.
- Validate server-side with an allowlist; enforce length limits.

Errors, rate limits, secrets
- Rate-limit authentication endpoints; make failure responses and timing identical for "no such user" and "wrong password" (no enumeration — do not skip the hash on the missing-user path).
- Fail closed on exception; never return `True`/allow in an `except`.
- No stack traces to users; log with context and a correlation id.
- Secrets in env/vault, never in code, URLs, or logs.
- **Browser-facing apps:** an unauthenticated HTML route must redirect to the login page — returning a raw JSON 401 to a browser is a defect, not a style choice.

If the code calls an LLM or is an agent, also apply LLM01/LLM05/LLM06 and ASI01–ASI03: untrusted input never concatenated into system prompts, model output treated as untrusted before any sink, minimal least-privilege tool surface, short-lived scoped credentials.
<!-- gate:end -->

## Depth

Read the full skill now and follow it — it carries the Top 10:2025 table, secure/unsafe code pairs, ASVS levels, the LLM & Agentic Top 10, and per-language footguns for 20 languages:

```
~/.claude/extern/claude-code-owasp/.claude/skills/owasp-security/SKILL.md
```

Related extern skills — load when the task touches them:
- Insecure defaults in frameworks/libs: `~/.claude/extern/trailofbits-skills/plugins/insecure-defaults/README.md`
- Footgun APIs / sharp edges: `~/.claude/extern/trailofbits-skills/plugins/sharp-edges/README.md`
- Writing custom semgrep rules: `~/.claude/extern/trailofbits-skills/plugins/semgrep-rule-creator/README.md`

CLI helpers: `semgrep scan` (SAST), `curl https://api.osv.dev/v1/query` (CVE lookup).
