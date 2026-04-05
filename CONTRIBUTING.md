# Contributing to CursorMobileS

Thanks for contributing.

## Project scope

CursorMobileS is a macOS-first setup toolkit focused on:

- Cursor Agent worker lifecycle
- GitHub CLI onboarding
- Optional Cloudflare Tunnel for cross-device checks
- Local dashboard UX

## Development workflow

1. Create a branch from `main`.
2. Make focused changes.
3. Run local checks:

```bash
chmod +x scripts/*.sh scripts/lib/*.sh
bash -n setup scripts/*.sh scripts/lib/*.sh
shellcheck setup scripts/*.sh scripts/lib/*.sh
./scripts/ci-smoke.sh
```

4. If you changed `scripts/lib/*`, `setup`, or templates, rebuild bundle:

```bash
./scripts/build-bundle.sh
```

5. Open a PR with:
   - problem statement
   - test evidence
   - risk/rollback note

## Pull request quality bar

- Keep behavior backward compatible unless explicitly discussed.
- Avoid destructive defaults.
- Prefer secure defaults and explicit opt-in for network exposure.
- Update docs in the same PR when behavior changes.

## Coding notes

- Shell scripts should remain POSIX/Bash-friendly and readable.
- Keep user-facing messages bilingual only when already established in file style.
- Do not commit secrets or machine-local credentials.
