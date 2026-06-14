# Publishing Checklist

Use this when creating the public repository.

## Suggested Repository Metadata

Name:

```text
signal-cli-vps-installer
```

Description:

```text
One-command signal-cli JSON-RPC daemon installer for hardened Debian/Ubuntu VPS hosts.
```

Topics:

```text
signal-cli
signal
json-rpc
debian
ubuntu
systemd
vps
automation
self-hosted
shell
```

## Before Publishing

```bash
./scripts/check.sh
git status --short
```

Read the installer end to end before the first public commit:

```bash
less install.sh
```

## Initial Release Notes

```text
Initial release of the signal-cli VPS installer.

- Installs signal-cli in native or JVM mode.
- Creates a dedicated system user and private data directory.
- Runs signal-cli as a hardened systemd JSON-RPC daemon.
- Configures optional VPS hardening for UFW, fail2ban, sysctl, unattended upgrades, and SSH.
- Includes operations and security-model documentation.
```

## README Positioning

Lead with operational clarity:

- target OS and assumptions,
- default localhost-only JSON-RPC binding,
- explicit root-run review warning,
- systemd service and hardening details,
- clear commands for install, health check, logs, and restart.

Avoid claiming the installer provides JSON-RPC authentication, release signature verification, backups, or full host hardening.
