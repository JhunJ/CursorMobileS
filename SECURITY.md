# Security Policy

## Supported Scope

This repository is a local-first macOS setup/tooling project.  
Security-sensitive areas include:

- Local dashboard server actions (`setup` + `scripts/lib/dashboard_flow.sh`)
- Shell command execution paths triggered from dashboard actions
- Workspace path allowlist and file-handling logic
- Credential-related files (`~/.cloudflared`, `.env`, GitHub auth state)

## Secure Defaults

- Dashboard bind host defaults to `127.0.0.1`.
- LAN exposure requires explicit opt-in (`CURSOR_DASH_LAN=1` or custom `CURSOR_DASH_HOST`).
- Dashboard POST actions require same-origin checks.
- HTTP responses include defensive browser headers (CSP, frame deny, nosniff).

## Reporting a Vulnerability

If you find a security issue, please avoid opening a public issue with exploit details.

1. Provide a concise report with reproduction steps, impact, and suggested fix.
2. Include affected file paths and environment assumptions.
3. Send privately to maintainers through your preferred private channel.

We will acknowledge the report, validate impact, and coordinate a fix + disclosure timing.
