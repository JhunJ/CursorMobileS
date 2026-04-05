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
- LAN exposure requires explicit opt-in (`CURSOR_DASH_LAN=1`, `CURSOR_DASH_HOST=0.0.0.0`, or create an empty `~/.cursor-setup/dashboard-bind-lan` so every `./setup` binds on all interfaces).
- When bound to all interfaces, POST requests without `Origin`/`Referer` are allowed only from loopback or typical private LAN ranges (RFC1918 / link-local); same-origin rules still apply when those headers are present.
- HTTP responses include defensive browser headers (CSP, frame deny, nosniff).
- Cloudflare Tunnel configs written by this project use **`http://127.0.0.1:<port>`** for ingress `service:` — not the machine’s public IP. Credentials stay under **`~/.cloudflared/`** and must not be committed (see `.gitignore` and `./scripts/git-safe-verify.sh`).

## Reporting a Vulnerability

If you find a security issue, please avoid opening a public issue with exploit details.

1. Provide a concise report with reproduction steps, impact, and suggested fix.
2. Include affected file paths and environment assumptions.
3. Report privately through [GitHub Security Advisories](https://github.com/JhunJ/CursorMobileS/security/advisories/new) when possible.
4. If advisories are not available in your context, contact maintainers through a private channel and include a secure reply address.

## Response targets

- Initial acknowledgement: within 72 hours
- Triage update: within 7 days
- Coordinated disclosure target: after fix availability and maintainer agreement

We will acknowledge reports, validate impact, coordinate fixes, and avoid publishing sensitive exploit details before mitigation is available.
