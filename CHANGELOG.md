# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Removed

- Cloudflare Tunnel / `cloudflared` integration, dashboard Tunnel UI, and setup flags that referenced it. Local dashboard and docs now describe GitHub, Agent CLI, and Worker only.

### Added

- GitHub Actions CI workflow for shell syntax, shellcheck, smoke checks, and README asset validation.
- GitHub Actions release workflow for tagged releases (`v*`) with bundle + SHA-256 checksum upload.
- Contributor templates: issue forms, PR template, and contribution guide.
- Security policy hardening notes and vulnerability reporting guidance.

### Improved

- README alignment for secure-by-default local dashboard and LAN opt-in guidance.
- Screenshot pipeline usage and README asset integrity expectations.
