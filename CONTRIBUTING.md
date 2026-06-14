# Contributing

Keep changes small, reviewable, and easy to audit.

## Development

Run checks before opening a pull request:

```bash
./scripts/check.sh
```

When changing the installer:

- keep it POSIX-friendly where practical, but Bash is allowed;
- preserve `set -Eeuo pipefail`;
- avoid new runtime dependencies unless they are already standard on Debian/Ubuntu servers or strongly justified;
- validate untrusted input before using it in commands or config files;
- do not log secrets, account state, or message contents;
- update README and docs when flags, files, services, or security behavior change.

## Security-Sensitive Changes

For changes touching root execution, systemd, SSH, firewalling, downloaded artifacts, JSON-RPC binding, or linked-device data, include a short threat-model note in the pull request:

- what can go wrong,
- sensitive data involved,
- trust boundaries,
- relevant abuse cases,
- chosen mitigations.
