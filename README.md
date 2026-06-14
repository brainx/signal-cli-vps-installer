# signal-cli VPS Installer

[![CI](https://github.com/brainx/signal-cli-vps-installer/actions/workflows/ci.yml/badge.svg)](https://github.com/brainx/signal-cli-vps-installer/actions/workflows/ci.yml)

Install and run [signal-cli](https://github.com/AsamK/signal-cli) as a locked-down JSON-RPC systemd service on a fresh Debian or Ubuntu VPS.

This repo packages a single root-run installer for people who want Signal automation without hand-assembling Java/native binaries, system users, firewall defaults, fail2ban, sysctl hardening, and a hardened systemd unit.

## What It Sets Up

- Installs the latest or pinned `signal-cli` release.
- Supports SHA256 verification with `--sha256` or `--checksum-url`; unverified downloads require an explicit unsafe opt-in.
- Uses the native Linux build on `x86_64` by default, or JVM mode when requested.
- Creates a dedicated `signal-cli` system user and private data directory.
- Starts a localhost-only JSON-RPC daemon at `127.0.0.1:8080` by default.
- Optionally links a phone via QR code during setup.
- Enables UFW, fail2ban, unattended security upgrades, and conservative sysctl hardening by default.
- Writes a systemd service with `NoNewPrivileges`, strict filesystem protection, no ambient capabilities, and a narrow address-family allowlist.

## Target Systems

- Debian or Ubuntu server
- `systemd`
- `apt-get`
- Root or sudo access
- Signal installed on a primary phone for linked-device provisioning

## Quick Start

Clone the repo and inspect the installer:

```bash
git clone https://github.com/brainx/signal-cli-vps-installer.git
cd signal-cli-vps-installer
less install.sh
```

Preview the install plan:

```bash
./install.sh --dry-run --account +31612345678 --device-name HomeOps-Signal --version 0.14.5
```

Run with a pinned version and expected SHA256:

```bash
sudo ./install.sh --account +31612345678 --device-name HomeOps-Signal --version 0.14.5 --sha256 SHA256
```

Unverified downloads are intentionally noisy and must be explicit:

```bash
sudo ./install.sh --verify none --allow-unverified-download --account +31612345678 --version 0.14.5
```

The daemon binds to localhost by default:

```bash
curl -i http://127.0.0.1:8080/api/v1/check
```

## Common Options

```text
--account +31612345678       Signal account number in E.164 format.
--device-name NAME           Linked device name shown in Signal.
--bind HOST:PORT             JSON-RPC HTTP bind address.
--allow-public-bind          Allow non-localhost bind. Use only behind authenticated transport.
--install-mode auto|native|jvm
--version VERSION            Pin a signal-cli release.
--artifact-file PATH         Use a local release artifact instead of downloading one.
--verify auto|sha256|none    Release artifact verification mode.
--sha256 SHA256              Expected SHA256 for the downloaded release artifact.
--checksum-url URL           HTTPS URL to a SHA256 checksum file.
--allow-unverified-download  Permit an install without checksum verification.
--dry-run                    Print the install plan without system changes.
--no-link                    Install without QR linking now.
--ssh-hardening              Disable SSH password auth and harden SSH.
--no-ssh-hardening           Do not change SSH config.
--no-ufw                     Do not install, enable, or configure UFW.
--no-fail2ban                Do not install, enable, or configure fail2ban.
--no-sysctl-hardening        Do not install sysctl hardening profile.
--no-unattended-upgrades     Do not enable unattended security upgrades.
--apt-upgrade                Run apt-get upgrade -y before install.
```

Run `./install.sh --help` for the full option list.

## Install Modes

| Mode | Behavior |
|---|---|
| `auto` | Uses the native Linux release on `x86_64`/`amd64`; uses JVM mode on other architectures. |
| `native` | Uses the native Linux release. Fast startup, but limited to `x86_64`/`amd64`. |
| `jvm` | Uses the JVM release. Works on more architectures, but requires Java 25. |

## Hardening Applied

| Control | Default | File or target |
|---|---:|---|
| Localhost JSON-RPC bind | yes | `/etc/default/signal-cli` |
| Dedicated system user | yes | `signal-cli` |
| Private data directory | yes | `/var/lib/signal-cli` |
| UFW deny inbound | yes | system firewall |
| fail2ban SSH jail | yes | `/etc/fail2ban/jail.d/sshd.local` |
| systemd `NoNewPrivileges` | yes | `signal-cli.service` |
| systemd `ProtectSystem=strict` | yes | `signal-cli.service` |
| SSH password disable | optional | `/etc/ssh/sshd_config.d/99-signal-cli-hardening.conf` |

## Compatibility

| Target | Status |
|---|---|
| Debian 12 | CI validation and dry-run tests |
| Ubuntu 24.04 LTS | CI validation and dry-run tests |
| Debian 13 | planned |
| Ubuntu 26.04 LTS | planned |
| `x86_64`/`amd64` native | validation tests |
| ARM64 JVM | validation tests |

## After Install

Useful service commands:

```bash
systemctl status signal-cli --no-pager
journalctl -u signal-cli -f
systemctl restart signal-cli
```

Send-test template:

```bash
curl -sS -X POST http://127.0.0.1:8080/api/v1/rpc \
  -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc": "2.0",
    "method": "send",
    "params": {
      "account": "+YOUR_ACCOUNT_NUMBER",
      "recipient": ["+RECIPIENT_NUMBER"],
      "message": "test from signal-cli"
    },
    "id": 1
  }'
```

## Security Notes

Treat the JSON-RPC daemon as privileged automation infrastructure. It can send and receive Signal messages for the linked account.

- Keep the default localhost bind unless you have a separate authenticated transport such as a VPN, SSH tunnel, or private reverse proxy.
- Do not expose the signal-cli JSON-RPC port directly to the public internet.
- Read `install.sh` before running it as root.
- Use `--ssh-hardening` only after confirming you have working SSH key access.
- Store VPS credentials, Signal account access, and any downstream automation secrets outside this repo.

More detail:

- [Security model](docs/security-model.md)
- [Operations](docs/operations.md)
- [Checksum guidance](docs/checksums.md)
- [Backup and restore](docs/backup-restore.md)
- [Troubleshooting](docs/troubleshooting.md)

## Development Checks

```bash
./scripts/check.sh
```

The check script always runs Bash syntax validation and the validation test suite. It also runs ShellCheck and shfmt when those tools are installed.

## License

MIT. See [LICENSE](LICENSE).
